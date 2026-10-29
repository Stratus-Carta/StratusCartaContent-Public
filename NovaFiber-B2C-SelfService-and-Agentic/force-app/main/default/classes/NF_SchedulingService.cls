/**
 * NF_SchedulingService
 * Installation booking on native Field Service objects, after the order is placed.
 *
 *   Sites      a household order has one site ('main', the order's shipping address); a multi-site business
 *              order has one per QuoteLineItemRecipient of its quote.
 *   Slots      2-hour arrival windows (8–10, 10–12, 1–3, territory time zone), Mon–Sat, two working weeks from
 *              the earliest install date (equipment ships first). A window is free for a crew when none of its
 *              assigned appointments overlaps the job (window start + work type duration).
 *   Booking    WorkOrder (work type, territory, site address, NF_Order__c) → ServiceAppointment (arrival window,
 *              scheduled start/end, status Scheduled) → AssignedResource (the free crew). Booking again
 *              reschedules the same appointment.
 *
 * Visitors may only book their own order: the random NF_Booking_Token__c returned with the order confirmation
 * must match. Agents may book any order. Runs without sharing (guest visitors), called from NF_JourneyController
 * and the Nova agent actions.
 */
public without sharing class NF_SchedulingService {

    public static final String MAIN_SITE = 'main';
    @TestVisible private static final String HOME_WORK_TYPE = 'NovaFiber Home Installation';
    @TestVisible private static final String BUSINESS_WORK_TYPE = 'NovaFiber Business Site Installation';
    private static final List<Integer> WINDOW_START_HOURS = new List<Integer>{ 8, 10, 13 };
    private static final Integer WINDOW_HOURS = 2;
    private static final Integer HOME_LEAD_DAYS = 3;       // equipment ships before the visit
    private static final Integer BUSINESS_LEAD_DAYS = 5;   // site survey and circuit hand-off
    private static final Integer WORKING_DAYS = 12;        // two weeks, Mon–Sat
    private static final Set<String> INACTIVE_STATUSES = new Set<String>{ 'Canceled', 'Cannot Complete' };

    /** Tests pin "today" so the calendar is deterministic. */
    @TestVisible private static Date todayOverride;

    // ── Public API ───────────────────────────────────────────────────────────

    /** The order's sites and any appointment already booked for them. */
    public static List<NF_JourneyModels.InstallSite> sites(String orderId, String token, NF_JourneyModels.JourneyContext ctx) {
        Order o = loadOrder(orderId, token, ctx);
        Map<String, WorkOrder> booked = workOrders(o.Id);
        List<NF_JourneyModels.InstallSite> out = new List<NF_JourneyModels.InstallSite>();
        for (SiteInfo s : siteInfos(o)) {
            NF_JourneyModels.InstallSite site = new NF_JourneyModels.InstallSite();
            site.siteKey = s.key;
            site.name = s.name;
            site.address = s.address();
            site.state = s.state;
            site.appointment = booked.containsKey(s.key) ? appointment(booked.get(s.key)) : null;
            out.add(site);
        }
        return out;
    }

    /** Free arrival windows for one site of the order. */
    public static NF_JourneyModels.InstallCalendar slots(String orderId, String token, String siteKey,
                                                         NF_JourneyModels.JourneyContext ctx) {
        Order o = loadOrder(orderId, token, ctx);
        SiteInfo site = site(o, siteKey);
        Plan p = plan(site, o);
        WorkOrder existing = workOrders(o.Id).get(site.key);

        NF_JourneyModels.InstallCalendar cal = new NF_JourneyModels.InstallCalendar();
        cal.siteKey = site.key;
        cal.siteName = site.name;
        cal.address = site.address();
        cal.territoryName = p.territory.Name;
        cal.timeZone = p.tzId;
        cal.workType = p.workType.Name;
        cal.durationHours = p.durationHours;
        cal.crews = p.crewIds.size();
        cal.appointment = existing == null ? null : appointment(existing);
        cal.days = new List<NF_JourneyModels.SlotDay>();

        Busy busy = busy(p, existing?.ServiceAppointments.isEmpty() == false ? existing.ServiceAppointments[0].Id : null);
        for (Date d : p.days) {
            NF_JourneyModels.SlotDay day = new NF_JourneyModels.SlotDay();
            DateTime noon = toUtc(d, 12, p.tz);
            day.dateKey = String.valueOf(d);
            day.weekday = noon.format('EEE', p.tzId);
            day.label = noon.format('MMM d', p.tzId);
            day.available = 0;
            day.slots = new List<NF_JourneyModels.Slot>();
            for (Integer h : WINDOW_START_HOURS) {
                DateTime start = toUtc(d, h, p.tz);
                NF_JourneyModels.Slot s = new NF_JourneyModels.Slot();
                s.slotKey = start.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
                s.label = windowLabel(h);
                s.available = busy.freeCrews(start, start.addMinutes(Integer.valueOf(p.durationHours * 60))).size();
                day.available += s.available;
                day.slots.add(s);
            }
            cal.days.add(day);
        }
        cal.timeZoneLabel = cal.days.isEmpty() ? '' : toUtc(p.days[0], 12, p.tz).format('z', p.tzId);
        return cal;
    }

    /** Books (or reschedules) the site's installation in the chosen arrival window. */
    public static NF_JourneyModels.InstallAppointment book(String orderId, String token, String siteKey, String slotKey,
                                                           NF_JourneyModels.JourneyContext ctx) {
        Order o = loadOrder(orderId, token, ctx);
        SiteInfo site = site(o, siteKey);
        Plan p = plan(site, o);
        DateTime start = parseSlot(slotKey);
        if (!isOffered(p, start)) {
            throw new NF_JourneyModels.JourneyException('That arrival window is not available. Please pick another one.');
        }
        DateTime finish = start.addMinutes(Integer.valueOf(p.durationHours * 60));

        WorkOrder wo = workOrders(o.Id).get(site.key);
        ServiceAppointment sa = wo == null || wo.ServiceAppointments.isEmpty() ? null : wo.ServiceAppointments[0];
        List<Id> free = busy(p, sa?.Id).freeCrews(start, finish);
        if (free.isEmpty()) {
            throw new NF_JourneyModels.JourneyException('That arrival window was just taken. Please pick another one.');
        }
        Id crewId = free[0];

        if (wo == null) {
            wo = new WorkOrder(AccountId = o.AccountId, ContactId = o.BillToContactId, WorkTypeId = p.workType.Id,
                ServiceTerritoryId = p.territory.Id, Status = 'New', Priority = site.isBusiness ? 'High' : 'Medium',
                Subject = ('Installation · Order ' + o.OrderNumber + ' · ' + site.name).left(255),
                Description = 'Install and activate the services of order ' + o.OrderNumber + ' at ' + site.address() + '.',
                Street = site.street, City = site.city, State = site.state, PostalCode = site.postalCode, Country = 'US',
                Duration = p.durationHours, DurationType = 'Hours',
                NF_Order__c = o.Id, NF_Site_Key__c = site.key, NF_Site_Name__c = site.name);
            insert wo;
            NF_Trace.rec('INSERT', wo, 'installation work order · ' + p.workType.Name);
        }
        Boolean reschedule = sa != null;
        if (sa == null) {
            sa = new ServiceAppointment(ParentRecordId = wo.Id, ContactId = o.BillToContactId,
                Subject = ('Installation · ' + site.name).left(255),
                Street = site.street, City = site.city, State = site.state, PostalCode = site.postalCode, Country = 'US');
        }
        sa.ServiceTerritoryId = p.territory.Id;
        sa.Status = 'Scheduled';
        sa.Duration = p.durationHours;
        sa.DurationType = 'Hours';
        sa.EarliestStartTime = start;
        sa.DueDate = finish.addDays(1);
        sa.ArrivalWindowStartTime = start;
        sa.ArrivalWindowEndTime = start.addHours(WINDOW_HOURS);
        sa.SchedStartTime = start;
        sa.SchedEndTime = finish;
        upsert sa;
        NF_Trace.rec(reschedule ? 'UPDATE' : 'INSERT', sa, (reschedule ? 'rescheduled' : 'scheduled') + ' · arrival ' + windowLabel(p, start));

        List<AssignedResource> old = [SELECT Id FROM AssignedResource WHERE ServiceAppointmentId = :sa.Id];
        if (!old.isEmpty()) delete old;
        AssignedResource ar = new AssignedResource(ServiceAppointmentId = sa.Id, ServiceResourceId = crewId);
        insert ar;
        NF_Trace.rec('INSERT', ar, 'crew assigned');

        return appointment(workOrders(o.Id).get(site.key));
    }

    /** Booking token for a new order: shown to nobody, returned once with the order confirmation. */
    public static String newToken() {
        return EncodingUtil.convertToHex(Crypto.generateAesKey(128));
    }

    // ── Order and sites ──────────────────────────────────────────────────────

    private static Order loadOrder(String orderId, String token, NF_JourneyModels.JourneyContext ctx) {
        List<Order> rows = !isId(orderId) ? new List<Order>() : [
            SELECT Id, OrderNumber, AccountId, BillToContactId, QuoteId, Quote.Name, NF_Booking_Token__c,
                   ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode
            FROM Order WHERE Id = :orderId LIMIT 1
        ];
        Boolean allowed = !rows.isEmpty() && (ctx.isAgent == true
            || (String.isNotBlank(token) && token == rows[0].NF_Booking_Token__c));
        if (!allowed) throw new NF_JourneyModels.JourneyException('We could not find your order.');
        NF_Trace.dml('READ', rows, 'order to schedule');
        return rows[0];
    }

    private class SiteInfo {
        String key;
        String name;
        String street;
        String city;
        String state;
        String postalCode;
        Boolean isBusiness = false;
        String address() {
            return String.join(new List<String>{ street, city, (state ?? '') + ' ' + (postalCode ?? '') }, ', ').normalizeSpace();
        }
    }

    private static List<SiteInfo> siteInfos(Order o) {
        List<SiteInfo> out = new List<SiteInfo>();
        if (o.QuoteId != null && (o.Quote.Name ?? '').startsWith(NF_MultiSiteService.QUOTE_PREFIX)) {
            for (QuoteLineItemRecipient r : [
                SELECT Id, Name, ServiceStreet, ServiceCity, ServiceState, ServicePostalCode
                FROM QuoteLineItemRecipient WHERE QuoteId = :o.QuoteId ORDER BY Name
            ]) {
                SiteInfo s = new SiteInfo();
                s.key = r.Id;
                // "Site 01 - HQ New York - 350 5th Ave, New York NY" → "HQ New York"
                List<String> parts = r.Name.split(' - ');
                s.name = parts.size() >= 3 ? parts[1] : r.Name;
                s.street = r.ServiceStreet;
                s.city = r.ServiceCity;
                s.state = r.ServiceState;
                s.postalCode = r.ServicePostalCode;
                s.isBusiness = true;
                out.add(s);
            }
            return out;
        }
        SiteInfo s = new SiteInfo();
        s.key = MAIN_SITE;
        s.name = 'Home';
        s.street = o.ShippingStreet;
        s.city = o.ShippingCity;
        s.state = o.ShippingState;
        s.postalCode = o.ShippingPostalCode;
        out.add(s);
        return out;
    }

    private static SiteInfo site(Order o, String siteKey) {
        for (SiteInfo s : siteInfos(o)) {
            if (s.key == (String.isBlank(siteKey) ? MAIN_SITE : siteKey)) return s;
        }
        throw new NF_JourneyModels.JourneyException('We could not find that service location on the order.');
    }

    /** Installation work orders of the order by site key, newest appointment first. */
    private static Map<String, WorkOrder> workOrders(Id orderId) {
        Map<String, WorkOrder> out = new Map<String, WorkOrder>();
        for (WorkOrder wo : [
            SELECT Id, WorkOrderNumber, NF_Site_Key__c, NF_Site_Name__c, ServiceTerritory.Name,
                   ServiceTerritory.OperatingHours.TimeZone,
                   (SELECT Id, AppointmentNumber, Status, ArrivalWindowStartTime, ArrivalWindowEndTime, SchedStartTime
                    FROM ServiceAppointments ORDER BY CreatedDate DESC LIMIT 1)
            FROM WorkOrder WHERE NF_Order__c = :orderId ORDER BY CreatedDate
        ]) {
            out.put(wo.NF_Site_Key__c, wo);
        }
        return out;
    }

    private static NF_JourneyModels.InstallAppointment appointment(WorkOrder wo) {
        NF_JourneyModels.InstallAppointment a = new NF_JourneyModels.InstallAppointment();
        a.siteKey = wo.NF_Site_Key__c;
        a.siteName = wo.NF_Site_Name__c;
        a.workOrderId = wo.Id;
        a.workOrderNumber = wo.WorkOrderNumber;
        a.territoryName = wo.ServiceTerritory?.Name;
        if (wo.ServiceAppointments.isEmpty()) return a;
        ServiceAppointment sa = wo.ServiceAppointments[0];
        a.appointmentId = sa.Id;
        a.appointmentNumber = sa.AppointmentNumber;
        a.status = sa.Status;
        String tzId = wo.ServiceTerritory?.OperatingHours?.TimeZone ?? 'America/New_York';
        if (sa.ArrivalWindowStartTime != null) {
            a.slotKey = sa.ArrivalWindowStartTime.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
            a.dateLabel = sa.ArrivalWindowStartTime.format('EEEE, MMM d', tzId);
            a.windowLabel = windowLabel(Integer.valueOf(sa.ArrivalWindowStartTime.format('H', tzId)))
                + ' ' + sa.ArrivalWindowStartTime.format('z', tzId);
        }
        List<AssignedResource> crew = [SELECT ServiceResource.Name FROM AssignedResource WHERE ServiceAppointmentId = :sa.Id LIMIT 1];
        a.crewName = crew.isEmpty() ? null : crew[0].ServiceResource.Name;
        return a;
    }

    // ── Territory, crews and calendar ────────────────────────────────────────

    private class Plan {
        ServiceTerritory territory;
        Timezone tz;
        String tzId;
        WorkType workType;
        Decimal durationHours;
        List<Id> crewIds = new List<Id>();
        List<Date> days = new List<Date>();
    }

    private static Plan plan(SiteInfo site, Order o) {
        List<ServiceTerritory> sts = [
            SELECT Id, Name, OperatingHours.TimeZone FROM ServiceTerritory
            WHERE State = :site.state AND IsActive = true AND Name LIKE 'NovaFiber %' LIMIT 1
        ];
        if (sts.isEmpty()) {
            throw new NF_JourneyModels.JourneyException('Online booking is not available in ' + site.state
                + ' yet; our installation team will call to schedule your visit.');
        }
        Plan p = new Plan();
        p.territory = sts[0];
        p.tzId = sts[0].OperatingHours?.TimeZone ?? 'America/New_York';
        p.tz = Timezone.getTimeZone(p.tzId);
        String wtName = site.isBusiness ? BUSINESS_WORK_TYPE : HOME_WORK_TYPE;
        List<WorkType> wts = [SELECT Id, Name, EstimatedDuration, DurationType FROM WorkType WHERE Name = :wtName LIMIT 1];
        if (wts.isEmpty()) throw new NF_JourneyModels.JourneyException('Installation booking is not set up yet.');
        p.workType = wts[0];
        p.durationHours = wts[0].DurationType == 'Minutes' ? wts[0].EstimatedDuration / 60 : wts[0].EstimatedDuration;

        DateTime now = DateTime.now();
        for (ServiceTerritoryMember m : [
            SELECT ServiceResourceId FROM ServiceTerritoryMember
            WHERE ServiceTerritoryId = :p.territory.Id AND ServiceResource.IsActive = true
              AND ServiceResource.ResourceType = 'C' AND EffectiveStartDate <= :now
              AND (EffectiveEndDate = null OR EffectiveEndDate > :now)
            ORDER BY ServiceResource.Name
        ]) {
            p.crewIds.add(m.ServiceResourceId);
        }
        NF_Trace.note('FSL', 'Territory ' + p.territory.Name, p.crewIds.size() + ' install crews · ' + p.tzId + ' · ' + p.workType.Name);

        // Working days (Mon–Sat) from the earliest install date, counted in the territory's time zone.
        Date today = todayOverride ?? Date.valueOf(now.format('yyyy-MM-dd', p.tzId));
        Date d = today.addDays(site.isBusiness ? BUSINESS_LEAD_DAYS : HOME_LEAD_DAYS);
        while (p.days.size() < WORKING_DAYS) {
            if (toUtc(d, 12, p.tz).format('EEE', p.tzId) != 'Sun') p.days.add(d);
            d = d.addDays(1);
        }
        return p;
    }

    /** Crew calendars over the plan's horizon (one query), ignoring the appointment being rescheduled. */
    private class Busy {
        Map<Id, List<ServiceAppointment>> byCrew = new Map<Id, List<ServiceAppointment>>();
        List<Id> crewIds;
        List<Id> freeCrews(DateTime start, DateTime finish) {
            List<Id> out = new List<Id>();
            for (Id crew : crewIds) {
                Boolean free = true;
                for (ServiceAppointment sa : byCrew.get(crew) ?? new List<ServiceAppointment>()) {
                    if (sa.SchedStartTime < finish && sa.SchedEndTime > start) { free = false; break; }
                }
                if (free) out.add(crew);
            }
            return out;
        }
    }

    private static Busy busy(Plan p, Id ignoreAppointmentId) {
        Busy b = new Busy();
        b.crewIds = p.crewIds;
        DateTime fromUtc = toUtc(p.days[0], 0, p.tz);
        DateTime toUtcEnd = toUtc(p.days[p.days.size() - 1], 23, p.tz);
        List<AssignedResource> rows = [
            SELECT ServiceResourceId, ServiceAppointmentId, ServiceAppointment.SchedStartTime, ServiceAppointment.SchedEndTime
            FROM AssignedResource
            WHERE ServiceResourceId IN :p.crewIds AND ServiceAppointmentId != :ignoreAppointmentId
              AND ServiceAppointment.SchedStartTime < :toUtcEnd AND ServiceAppointment.SchedEndTime > :fromUtc
              AND ServiceAppointment.Status NOT IN :INACTIVE_STATUSES
        ];
        for (AssignedResource ar : rows) {
            if (!b.byCrew.containsKey(ar.ServiceResourceId)) b.byCrew.put(ar.ServiceResourceId, new List<ServiceAppointment>());
            b.byCrew.get(ar.ServiceResourceId).add(ar.ServiceAppointment);
        }
        NF_Trace.dml('READ', rows, 'crew calendars · ' + p.days.size() + ' working days');
        return b;
    }

    private static Boolean isOffered(Plan p, DateTime start) {
        for (Date d : p.days) {
            for (Integer h : WINDOW_START_HOURS) {
                if (toUtc(d, h, p.tz) == start) return true;
            }
        }
        return false;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static Boolean isId(String value) {
        if (String.isBlank(value)) return false;
        try {
            Id.valueOf(value);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /** Local wall-clock hour on a date in the given time zone → UTC instant. */
    @TestVisible
    private static DateTime toUtc(Date d, Integer hour, Timezone tz) {
        DateTime asGmt = DateTime.newInstanceGmt(d, Time.newInstance(hour, 0, 0, 0));
        return asGmt.addSeconds(-tz.getOffset(asGmt) / 1000);
    }

    private static DateTime parseSlot(String slotKey) {
        try {
            return (DateTime) JSON.deserialize('"' + slotKey + '"', DateTime.class);
        } catch (Exception e) {
            throw new NF_JourneyModels.JourneyException('Please pick an arrival window.');
        }
    }

    private static String windowLabel(Plan p, DateTime start) {
        return start.format('EEE MMM d', p.tzId) + ', ' + windowLabel(Integer.valueOf(start.format('H', p.tzId)));
    }

    @TestVisible
    private static String windowLabel(Integer startHour) {
        Integer endHour = startHour + WINDOW_HOURS;
        String startLabel = hour12(startHour);
        String endLabel = hour12(endHour);
        Boolean sameHalf = (startHour < 12) == (endHour < 12);
        return (sameHalf ? startLabel.substringBefore(' ') : startLabel) + '–' + endLabel;
    }

    private static String hour12(Integer h) {
        Integer v = Math.mod(h, 12) == 0 ? 12 : Math.mod(h, 12);
        return v + (h < 12 ? ' AM' : ' PM');
    }
}
