import { LightningElement, api } from 'lwc';
import { api as nfApi } from 'c/nfApi';
import { reduceError } from 'c/nfUtils';

const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/**
 * Installation booking for one site of a placed order (NF_SchedulingService on Field Service objects):
 * a two-week Mon–Sat calendar of the territory's crew availability, 2-hour arrival windows for the chosen day,
 * then a work order, service appointment and assigned crew. Booking again reschedules.
 */
export default class NfInstallBooking extends LightningElement {
    @api orderId;
    @api bookingToken;
    @api siteKey = 'main';
    @api siteName;
    /** Already booked (from the order's sites, or by Nova in the chat): show it instead of the calendar. */
    @api
    get appointment() {
        return this.booked;
    }
    set appointment(value) {
        if (value && value.appointmentId) {
            this.booked = value;
            this.editing = false;
        }
    }
    @api heading = 'Book your installation';

    calendar;
    selectedDate;
    selectedSlot;
    booked;
    editing = false;
    loading = false;
    saving = false;
    error;

    connectedCallback() {
        if (!this.booked) {
            this.load();
        }
    }

    async load() {
        this.loading = true;
        this.error = undefined;
        try {
            this.calendar = await nfApi.installSlots(this.orderId, this.bookingToken, this.siteKey);
            if (!this.booked && this.calendar.appointment) {
                this.booked = this.calendar.appointment;
            }
            const first = this.calendar.days.find((d) => d.available > 0);
            this.selectedDate = first ? first.dateKey : undefined;
            this.selectedSlot = undefined;
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.loading = false;
        }
    }

    get showCalendar() {
        return !!this.calendar && (!this.booked || this.editing);
    }
    get siteSuffix() {
        return this.siteName && this.siteName !== 'Home' ? ` · ${this.siteName}` : '';
    }
    get showBooked() {
        return !!this.booked && !this.editing;
    }
    get subtitle() {
        const c = this.calendar;
        if (!c) {
            return '';
        }
        const hours = Number(c.durationHours);
        return `${c.territoryName} · ${c.crews} install crew${c.crews === 1 ? '' : 's'} · about ${hours} hour${hours === 1 ? '' : 's'} on site · times in ${c.timeZoneLabel}`;
    }

    /** Calendar cells: blank cells before the first day so weekdays line up in Mon–Sat columns. */
    get cells() {
        if (!this.calendar) {
            return [];
        }
        const days = this.calendar.days;
        const lead = Math.max(0, WEEKDAYS.indexOf(days[0]?.weekday));
        const cells = [];
        for (let i = 0; i < lead; i++) {
            cells.push({ key: `pad${i}`, isPad: true, className: 'ib-day ib-day_pad' });
        }
        days.forEach((d) => {
            const full = d.available === 0;
            const selected = d.dateKey === this.selectedDate;
            cells.push({
                key: d.dateKey,
                dateKey: d.dateKey,
                weekday: d.weekday,
                dayNumber: d.label.split(' ')[1],
                month: d.label.split(' ')[0],
                availability: full ? 'Full' : `${d.slots.filter((s) => s.available > 0).length} of ${d.slots.length} open`,
                disabled: full,
                ariaLabel: `${d.weekday} ${d.label}, ${full ? 'fully booked' : 'available'}`,
                className: ['ib-day', full ? 'ib-day_full' : '', selected ? 'ib-day_selected' : ''].join(' ').trim()
            });
        });
        return cells;
    }
    get weekdayHeaders() {
        return WEEKDAYS;
    }

    get selectedDay() {
        return this.calendar?.days.find((d) => d.dateKey === this.selectedDate);
    }
    get daySlots() {
        const day = this.selectedDay;
        if (!day) {
            return [];
        }
        return day.slots.map((s) => {
            const full = s.available === 0;
            const selected = s.slotKey === this.selectedSlot;
            return {
                ...s,
                disabled: full,
                note: full ? 'Fully booked' : `${s.available} crew${s.available === 1 ? '' : 's'} free`,
                className: ['ib-slot', full ? 'ib-slot_full' : '', selected ? 'ib-slot_selected' : ''].join(' ').trim(),
                pressed: selected ? 'true' : 'false'
            };
        });
    }
    get selectedDayLabel() {
        const d = this.selectedDay;
        return d ? `${d.weekday}, ${d.label}` : '';
    }
    get bookLabel() {
        const day = this.selectedDay;
        const slot = day?.slots.find((s) => s.slotKey === this.selectedSlot);
        if (!slot) {
            return this.booked ? 'Pick a new window' : 'Pick an arrival window';
        }
        return `${this.booked ? 'Move to' : 'Book'} ${day.weekday} ${day.label}, ${slot.label}`;
    }
    get bookDisabled() {
        return this.saving || !this.selectedSlot;
    }
    get hasSlotsForDay() {
        return this.daySlots.length > 0;
    }

    handleDay(event) {
        const key = event.currentTarget.dataset.date;
        if (!key) {
            return;
        }
        this.selectedDate = key;
        this.selectedSlot = undefined;
    }
    handleSlot(event) {
        this.selectedSlot = event.currentTarget.dataset.slot;
    }

    async handleBook() {
        this.saving = true;
        this.error = undefined;
        try {
            this.booked = await nfApi.bookInstall(this.orderId, this.bookingToken, this.siteKey, this.selectedSlot);
            this.editing = false;
            this.dispatchEvent(new CustomEvent('booked', { detail: { siteKey: this.siteKey, appointment: this.booked } }));
        } catch (e) {
            this.error = reduceError(e);
            // the window may just have been taken: refresh availability
            await this.load();
        } finally {
            this.saving = false;
        }
    }

    handleChange() {
        this.editing = true;
        if (!this.calendar) {
            this.load();
        }
    }
    handleCancelChange() {
        this.editing = false;
    }
}
