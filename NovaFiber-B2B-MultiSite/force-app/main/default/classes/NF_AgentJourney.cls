/**
 * NF_AgentJourney
 * The NovaFiber journey as run by the Agentforce sales agent (NF_Sales_Agent) behind the website chat.
 *
 * The agent's actions (NF_AgentAction* invocable classes, run as the agent user) call these operations
 * with the chat's journey key. The journey lives in one NF_Agent_Journey__c record, so the website
 * (NF_AgentGateway) shows the same serviceability, offers, cart, quote and order as live cards.
 *
 * Every operation reuses the guided journey's services (serviceability mock, Product Discovery with
 * qualification, configurator sessions on the workspace quote, Place Sales Transaction, createOrdersFromQuote)
 * in a fixed "AI Agent" context with self-service rules: no discounts, no overrides, prospect accounts only.
 * Customer contact details never pass through the language model: the website form stores them here
 * (saveCustomer) and placeOrder reads them.
 * Operations make their callouts first and write the record last (no callouts after DML).
 */
public without sharing class NF_AgentJourney {

    public static final Integer MAX_ITEM_QUANTITY = 5;
    private static final Integer MAX_TRACE_CHARS = 120000;

    public class State {
        public NF_JourneyModels.ServiceabilityResult serviceability;
        public List<NF_JourneyModels.CartItem> items = new List<NF_JourneyModels.CartItem>();
        public NF_JourneyModels.QuoteSummary priced;     // configurator result for items (live session)
        public String quoteId;                           // the customer's draft quote, once saved
        public NF_JourneyModels.QuoteSummary quote;      // saved quote; matches the cart while quoteCurrent
        public Boolean quoteCurrent = false;
        public NF_JourneyModels.OrderResult order;
        public NF_JourneyModels.InstallAppointment appointment;   // installation booked in the chat or on the page
        public NF_JourneyModels.CustomerDetails customer;
        public Integer itemSeq = 0;
        public String focus;                             // what the page should bring into view after this turn (addons)
    }

    public class Journey {
        public NF_Agent_Journey__c rec;
        public State state;
    }

    /** One agent action: changes the journey and returns what the agent should know. */
    public interface Op {
        String run(Journey j);
    }

    public class Outcome {
        public Boolean success;
        public String summary;
        public State state;
    }

    // ── Running actions ──────────────────────────────────────────────────────

    /** Loads the journey, runs the operation, records its trace for the inspector and saves (DML last). */
    public static Outcome execute(String journeyKey, String actionName, Op op) {
        NF_Trace.enable();
        NF_JourneyCache.setMode(NF_JourneyCache.MODE_CACHED);
        NF_Trace.Entry root = NF_Trace.start('AGENT_ACTION', actionName, 'Agent action · runs as ' + UserInfo.getUserName());
        Outcome out = new Outcome();
        Journey j;
        try {
            j = load(journeyKey);
            out.summary = op.run(j);
            out.success = true;
            NF_Trace.end(root, 'OK', out.summary);
        } catch (NF_JourneyModels.JourneyException e) {
            out.success = false;
            out.summary = e.getMessage();
            NF_Trace.end(root, 'ERROR', e.getMessage());
        } catch (Exception e) {
            out.success = false;
            out.summary = 'That did not work because of a technical problem. Apologise and suggest trying again in a moment.';
            System.debug(LoggingLevel.ERROR, 'NF agent action ' + actionName + ' failed: ' + e.getTypeName() + ': '
                + e.getMessage() + '\n' + e.getStackTraceString());
            NF_Trace.end(root, 'ERROR', e.getTypeName() + ': ' + e.getMessage());
        }
        if (j != null) {
            save(j, NF_Trace.drain());
            out.state = j.state;
        }
        return out;
    }

    public static Journey load(String journeyKey) {
        List<NF_Agent_Journey__c> recs = String.isBlank(journeyKey) ? new List<NF_Agent_Journey__c>() : [
            SELECT Id, Name, Journey_Key__c, Session_Id__c, Sequence__c, Step__c, Quote_Id__c, Order_Id__c,
                   State__c, Pending_Trace__c, CreatedDate
            FROM NF_Agent_Journey__c WHERE Journey_Key__c = :journeyKey LIMIT 1
        ];
        if (recs.isEmpty()) {
            throw new NF_JourneyModels.JourneyException('This chat has expired. Ask the customer to start a new chat.');
        }
        Journey j = new Journey();
        j.rec = recs[0];
        j.state = String.isBlank(j.rec.State__c) ? new State() : (State) JSON.deserialize(j.rec.State__c, State.class);
        return j;
    }

    /** Writes the state and appends trace entries for the website inspector (oldest payloads dropped when large). */
    public static void save(Journey j, List<NF_Trace.Entry> trace) {
        j.rec.State__c = JSON.serialize(j.state, true);
        j.rec.Step__c = step(j.state);
        j.rec.Quote_Id__c = j.state.quoteId;
        j.rec.Order_Id__c = j.state.order?.orderId;
        if (trace != null && !trace.isEmpty()) {
            List<NF_Trace.Entry> pending = pendingTrace(j.rec);
            pending.addAll(trace);
            j.rec.Pending_Trace__c = fitTrace(pending);
        }
        update j.rec;
    }

    public static List<NF_Trace.Entry> pendingTrace(NF_Agent_Journey__c rec) {
        return String.isBlank(rec.Pending_Trace__c) ? new List<NF_Trace.Entry>()
            : (List<NF_Trace.Entry>) JSON.deserialize(rec.Pending_Trace__c, List<NF_Trace.Entry>.class);
    }

    private static String fitTrace(List<NF_Trace.Entry> entries) {
        String text = JSON.serialize(entries, true);
        Integer i = 0;
        while (text.length() > MAX_TRACE_CHARS && i < entries.size()) {
            entries[i].requestJson = null;
            entries[i].responseJson = null;
            i++;
            text = JSON.serialize(entries, true);
        }
        while (text.length() > MAX_TRACE_CHARS && !entries.isEmpty()) {
            entries.remove(0);
            text = JSON.serialize(entries, true);
        }
        return text;
    }

    public static String step(State s) {
        if (s.order != null) return 'done';
        if (s.quoteCurrent == true) return 'quote';
        if (!s.items.isEmpty()) return 'cart';
        if (s.serviceability != null) return 'offers';
        return 'address';
    }

    /** The agent sells with self-service rules; its quotes and orders carry the AI Agent channel. */
    public static NF_JourneyModels.JourneyContext context() {
        NF_JourneyModels.JourneyContext c = new NF_JourneyModels.JourneyContext();
        c.channel = NF_JourneyModels.CHANNEL_AI_AGENT;
        c.isAgent = false;
        c.isGuest = true;
        c.canDiscount = false;
        c.maxDiscountPercent = 0;
        c.canOverrideServiceability = false;
        c.canSelectAccount = false;
        c.currencyIsoCode = UserInfo.getDefaultCurrency();
        c.inspectorAllowed = false;
        c.journeyMode = NF_JourneyCache.MODE_CACHED;
        c.canFlushCache = false;
        return c;
    }

    // ── Operations ───────────────────────────────────────────────────────────

    public static String checkAddress(Journey j, NF_JourneyModels.Address a) {
        State s = j.state;
        if (s.order != null) {
            throw new NF_JourneyModels.JourneyException('Order ' + s.order.orderNumber
                + ' is already placed in this chat. The customer can start a new chat to shop for another address.');
        }
        if (a == null || String.isBlank(a.street) || String.isBlank(a.city) || String.isBlank(a.state)
            || String.isBlank(a.postalCode) || !Pattern.matches('\\d{5}', a.postalCode.trim())) {
            throw new NF_JourneyModels.JourneyException('A full US address is needed: street, city, 2-letter state and 5-digit ZIP code.');
        }
        a.state = a.state.trim().toUpperCase();
        a.postalCode = a.postalCode.trim();
        a.country = 'US';
        NF_JourneyModels.ServiceabilityResult r = NF_ServiceabilityService.check(a);

        String note = '';
        Boolean moved = s.serviceability != null && s.serviceability.address != null
            && s.serviceability.address.singleLine() != a.singleLine();
        if (moved) {
            if (!s.items.isEmpty()) note = ' The cart was emptied because the address changed.';
            discardQuote(s);
            s.items = new List<NF_JourneyModels.CartItem>();
            s.priced = null;
        }
        s.serviceability = r;
        return describeServiceability(r) + note;
    }

    public static String findPlans(Journey j, String category, Decimal maxMonthlyPrice, Decimal minDownloadMbps) {
        requireAddress(j.state);
        String wanted = String.isBlank(category) || category.equalsIgnoreCase('all') ? null : category.trim().toLowerCase();
        List<String> out = new List<String>();
        Integer shown = 0;
        for (NF_JourneyModels.OfferCategory c : NF_OfferService.getOffers(j.state.serviceability)) {
            if (wanted != null && !c.label.toLowerCase().contains(wanted) && !c.key.toLowerCase().contains(wanted)) continue;
            List<String> lines = new List<String>();
            for (NF_JourneyModels.Offer o : c.offers) {
                if (maxMonthlyPrice != null && o.price != null && o.price > maxMonthlyPrice) continue;
                if (minDownloadMbps != null && (o.downloadMbps == null || o.downloadMbps < minDownloadMbps)) continue;
                lines.add(describeOffer(o));
                shown++;
            }
            if (!lines.isEmpty()) out.add(c.label + ':\n' + String.join(lines, '\n'));
        }
        if (shown == 0) return 'No plans match that request at this address. Offer to show all available plans.';
        return 'Plans available at this address (qualified by Revenue Cloud for '
            + technologyProfile(j.state.serviceability) + '; prices per month before taxes):\n' + String.join(out, '\n\n')
            + '\nThe plan cards are also shown on the page.';
    }

    public static String updateCart(Journey j, String operation, String planCode, Decimal quantity,
                                    String addAddOns, String removeAddOns) {
        State s = j.state;
        requireAddress(s);
        if (s.order != null) throw new NF_JourneyModels.JourneyException('The order is already placed; the cart can no longer change.');
        String op = String.isBlank(operation) ? 'add' : operation.trim().toLowerCase();
        List<String> notes = new List<String>();

        if (op == 'clear') {
            s.items.clear();
        } else {
            List<NF_JourneyModels.Offer> offers = new List<NF_JourneyModels.Offer>();
            for (NF_JourneyModels.OfferCategory c : NF_OfferService.getOffers(s.serviceability)) offers.addAll(c.offers);
            NF_JourneyModels.Offer offer = findOffer(offers, planCode);
            NF_JourneyModels.CartItem item = itemFor(s, offer.productId);
            if (op == 'remove') {
                if (item == null) throw new NF_JourneyModels.JourneyException(offer.name + ' is not in the cart.');
                removeItem(s, item);
            } else if (op == 'add' || op == 'update') {
                if (item == null) {
                    if (op == 'update') throw new NF_JourneyModels.JourneyException(offer.name + ' is not in the cart yet. Add it first.');
                    if (s.items.size() >= 10) throw new NF_JourneyModels.JourneyException('The cart can hold at most 10 plans.');
                    item = new NF_JourneyModels.CartItem();
                    item.key = 'ai' + (++s.itemSeq);
                    item.productId = offer.productId;
                    item.quantity = 1;
                    item.options = defaultOptions(offer);
                    s.items.add(item);
                } else if (op == 'add' && quantity == null && String.isBlank(addAddOns) && String.isBlank(removeAddOns)) {
                    notes.add(offer.name + ' was already in the cart, so nothing changed.');
                }
                if (quantity != null) {
                    Integer q = quantity.intValue();
                    if (q < 1 || q > MAX_ITEM_QUANTITY) {
                        throw new NF_JourneyModels.JourneyException('Quantity must be between 1 and ' + MAX_ITEM_QUANTITY + '.');
                    }
                    item.quantity = q;
                }
                applyAddOns(item, offer, splitNames(addAddOns), splitNames(removeAddOns), notes);
            } else {
                throw new NF_JourneyModels.JourneyException('Unknown cart operation "' + operation + '". Use add, update, remove or clear.');
            }
        }

        s.quoteCurrent = false;
        if (s.items.isEmpty()) {
            s.priced = null;
            return (notes.isEmpty() ? '' : String.join(notes, ' ') + ' ') + 'The cart is now empty.';
        }
        s.priced = NF_QuoteService.syncCart(cartRequest(s), context());
        followRules(s);
        return (notes.isEmpty() ? '' : String.join(notes, ' ') + '\n') + describeCart(s);
    }

    /** The cart takes the options the configuration rules (CML) left on each plan; the rule notes tell Nova why. */
    private static void followRules(State s) {
        if (s.priced?.ruleAdjustments == null) return;
        for (NF_JourneyModels.RuleAdjustment adj : s.priced.ruleAdjustments) {
            for (NF_JourneyModels.CartItem item : s.items) {
                if (item.key == adj.itemKey) item.options = adj.options;
            }
        }
    }

    /** The add-ons (bundle options) of the plans in the cart; the page shows them in its Add-ons section. */
    public static String showAddOns(Journey j, String planCode) {
        State s = j.state;
        requireAddress(s);
        if (s.items.isEmpty()) {
            throw new NF_JourneyModels.JourneyException('The cart is empty. Add-ons belong to a plan: help the customer choose a plan first.');
        }
        Map<String, NF_JourneyModels.Offer> byId = new Map<String, NF_JourneyModels.Offer>();
        List<NF_JourneyModels.Offer> offers = new List<NF_JourneyModels.Offer>();
        for (NF_JourneyModels.OfferCategory c : NF_OfferService.getOffers(s.serviceability)) {
            for (NF_JourneyModels.Offer o : c.offers) { byId.put(o.productId, o); offers.add(o); }
        }
        String onlyId = String.isBlank(planCode) ? null : findOffer(offers, planCode).productId;
        List<String> out = new List<String>();
        for (NF_JourneyModels.CartItem item : s.items) {
            NF_JourneyModels.Offer offer = byId.get(item.productId);
            if (offer == null || (onlyId != null && offer.productId != onlyId)) continue;
            Set<String> chosen = new Set<String>();
            for (NF_JourneyModels.SelectedOption so : item.options) chosen.add(so.componentId);
            List<String> groups = new List<String>();
            for (NF_JourneyModels.OptionGroup g : offer.groups == null ? new List<NF_JourneyModels.OptionGroup>() : offer.groups) {
                List<String> opts = new List<String>();
                for (NF_JourneyModels.Option o : g.options) {
                    opts.add(o.name + ' ' + (o.price == null || o.price == 0 ? 'included' : money(o.price)
                        + (o.chargeType == 'One-Time' ? ' one-time' : '/month'))
                        + (o.isRequired == true ? ' [required]' : chosen.contains(o.componentId) ? ' [in cart]' : ''));
                }
                groups.add(g.name + (g.maxOptions == 1 ? ' (choose one)' : '') + ': ' + String.join(opts, '; '));
            }
            out.add(offer.name + ' [code ' + offer.productCode + ']:\n' + (groups.isEmpty() ? 'no add-ons' : String.join(groups, '\n')));
        }
        if (out.isEmpty()) throw new NF_JourneyModels.JourneyException('That plan is not in the cart.');
        s.focus = 'addons';
        return 'Add-ons for the plans in the cart (also shown in the Add-ons section on the page, where the customer can add them):\n'
            + String.join(out, '\n\n');
    }

    public static String saveQuote(Journey j) {
        State s = j.state;
        requireAddress(s);
        if (s.order != null) return 'Order ' + s.order.orderNumber + ' is already placed.';
        if (s.items.isEmpty()) throw new NF_JourneyModels.JourneyException('The cart is empty. Help the customer choose a plan first.');
        if (s.priced != null && s.priced.hasErrors == true) {
            throw new NF_JourneyModels.JourneyException('The cart has configuration errors that must be fixed first: ' + errorText(s.priced));
        }
        NF_JourneyModels.QuoteSummary saved = NF_QuoteService.saveQuote(cartRequest(s), context());
        s.quote = saved;
        s.quoteId = saved.quoteId;
        s.quoteCurrent = true;
        return 'Quote ' + saved.quoteNumber + ' is saved in Revenue Cloud:\n' + describeLines(saved)
            + '\nNext: ask the customer to review the quote on the page, complete the secure checkout form there '
            + '(name, email, phone, preferred install date and terms) and e-sign the service agreement that then appears on the page. '
            + 'Never ask for these details in the chat.';
    }

    /** From the website form (never through the language model). */
    public static void saveCustomer(Journey j, NF_JourneyModels.CustomerDetails c) {
        NF_OrderService.validateCustomer(c, context());
        if (j.state.order != null) throw new NF_JourneyModels.JourneyException('This order is already placed.');
        // The My NovaFiber login is created now so the password never sits in the journey record.
        if (String.isNotBlank(c.portalPassword)) {
            NF_PortalService.register(j.state.quote?.accountId, null, c.email, c.portalPassword);
            c.portalPassword = null;
        }
        j.state.customer = c;
    }

    public static String placeOrder(Journey j) {
        State s = j.state;
        if (s.order != null) {
            return 'Order ' + s.order.orderNumber + ' was already placed. Do not place it again.';
        }
        if (s.quoteCurrent != true || s.quoteId == null) {
            throw new NF_JourneyModels.JourneyException('There is no up-to-date quote. Save the quote for the current cart first.');
        }
        if (s.customer == null) {
            throw new NF_JourneyModels.JourneyException('The customer has not completed the secure checkout form on the page yet. '
                + 'Ask them to complete it; do not ask for the details in the chat.');
        }
        NF_JourneyModels.OrderResult r = NF_OrderService.submit(s.quoteId, s.customer, context());
        s.order = r;
        s.customer = null;   // contact details are on the account and contact now
        return 'Order ' + r.orderNumber + ' is placed (status ' + r.status + ') for ' + r.accountName
            + '. Monthly ' + money(r.monthlyTotal) + ', one-time ' + money(r.oneTimeTotal)
            + (r.installDate == null ? '' : ', preferred installation ' + r.installDate.format())
            + '. The order is now being fulfilled (network, equipment, installation and billing); the customer can follow'
            + ' every step in My NovaFiber on this site, logging in with their email and the password from the checkout form.'
            + ' Next: offer to book the installation visit now (get_install_slots), or the customer can pick a time in the calendar on the page.';
    }

    // ── Installation booking (Field Service, NF_SchedulingService) ───────────

    /** Free arrival windows for the household's installation, optionally from a date and for a part of the day. */
    public static String installSlots(Journey j, String fromDate, String partOfDay) {
        State s = requireOrder(j);
        NF_JourneyModels.InstallCalendar cal = NF_SchedulingService.slots(s.order.orderId, s.order.bookingToken,
            NF_SchedulingService.MAIN_SITE, context());
        if (cal.appointment != null && cal.appointment.appointmentId != null) s.appointment = cal.appointment;
        Date fromDay = null;
        try {
            if (String.isNotBlank(fromDate)) fromDay = Date.valueOf(fromDate.trim());
        } catch (Exception e) {
            fromDay = null;
        }
        String part = (partOfDay ?? '').trim().toLowerCase();
        List<String> lines = new List<String>();
        for (NF_JourneyModels.SlotDay d : cal.days) {
            if (fromDay != null && Date.valueOf(d.dateKey) < fromDay) continue;
            for (NF_JourneyModels.Slot slot : d.slots) {
                if (slot.available == 0) continue;
                Boolean morning = slot.label.endsWith('AM') || slot.label.startsWith('10 AM');
                if (part == 'morning' && !morning) continue;
                if (part == 'afternoon' && morning) continue;
                lines.add('- ' + d.weekday + ' ' + d.label + ', ' + slot.label + ' ' + cal.timeZoneLabel + ' (slot key ' + slot.slotKey + ')');
                if (lines.size() >= 6) break;
            }
            if (lines.size() >= 6) break;
        }
        s.focus = 'install';
        String booked = s.appointment == null ? '' : 'Currently booked: ' + s.appointment.dateLabel + ', ' + s.appointment.windowLabel + '.\n';
        if (lines.isEmpty()) {
            return booked + 'No free arrival windows match that request in the next two weeks. Suggest another day or part of the day; '
                + 'the full calendar is also on the page.';
        }
        return booked + 'Free installation arrival windows (' + cal.territoryName + ', about ' + cal.durationHours.stripTrailingZeros()
            + ' hours on site, a two-technician crew):\n' + String.join(lines, '\n')
            + '\nOffer two or three of these in plain words (never show slot keys). Book with book_install and the slot key of the window the customer picks.';
    }

    public static String bookInstall(Journey j, String slotKey) {
        State s = requireOrder(j);
        if (String.isBlank(slotKey)) throw new NF_JourneyModels.JourneyException('Pick a window from get_install_slots first.');
        Boolean reschedule = s.appointment != null;
        s.appointment = NF_SchedulingService.book(s.order.orderId, s.order.bookingToken, NF_SchedulingService.MAIN_SITE,
            slotKey.trim(), context());
        s.focus = 'install';
        return 'Installation ' + (reschedule ? 'rescheduled' : 'booked') + ': ' + s.appointment.dateLabel + ', technicians arrive '
            + s.appointment.windowLabel + ' (' + s.appointment.crewName + ', work order ' + s.appointment.workOrderNumber
            + '). It also shows on the page; the customer can change it there or ask you.';
    }

    private static State requireOrder(Journey j) {
        if (j.state.order == null) {
            throw new NF_JourneyModels.JourneyException('The order is not placed yet; installation can be booked once it is.');
        }
        return j.state;
    }

    public static String status(Journey j) {
        State s = j.state;
        List<String> parts = new List<String>();
        parts.add('Step: ' + step(s) + '.');
        parts.add(s.serviceability == null ? 'Address: not checked yet.' : describeServiceability(s.serviceability));
        parts.add(s.items.isEmpty() ? 'Cart: empty.' : describeCart(s));
        if (s.quoteId != null) {
            parts.add(s.quoteCurrent == true ? 'Quote ' + s.quote.quoteNumber + ' is saved and matches the cart.'
                : 'The cart changed since quote ' + s.quote?.quoteNumber + ' was saved; save the quote again before ordering.');
        }
        parts.add('Secure checkout form completed: ' + (s.customer != null ? 'yes' : 'no') + '.');
        if (s.order != null) parts.add('Order ' + s.order.orderNumber + ' is placed.');
        if (s.appointment != null) parts.add('Installation booked: ' + s.appointment.dateLabel + ', ' + s.appointment.windowLabel + '.');
        return String.join(parts, '\n');
    }

    /** Ends a chat that never ordered: deletes its draft quote (and prospect account). */
    public static void discardQuote(State s) {
        if (s.quoteId != null && s.order == null) {
            NF_QuoteService.discard(s.quoteId, context());
        }
        s.quoteId = null;
        s.quote = null;
        s.quoteCurrent = false;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    public static NF_JourneyModels.CartRequest cartRequest(State s) {
        NF_JourneyModels.CartRequest req = new NF_JourneyModels.CartRequest();
        req.serviceability = s.serviceability;
        req.items = s.items;
        req.quoteId = s.quoteId;
        req.contextId = s.priced?.contextId;
        req.lineIds = s.priced?.sessionLineIds;
        return req;
    }

    private static void requireAddress(State s) {
        if (s.serviceability == null) {
            throw new NF_JourneyModels.JourneyException('The address has not been checked yet. Ask for the customer\'s address first.');
        }
    }

    private static NF_JourneyModels.CartItem itemFor(State s, String productId) {
        for (NF_JourneyModels.CartItem i : s.items) if (i.productId == productId) return i;
        return null;
    }

    private static void removeItem(State s, NF_JourneyModels.CartItem item) {
        for (Integer i = s.items.size() - 1; i >= 0; i--) if (s.items[i].key == item.key) s.items.remove(i);
    }

    @TestVisible
    private static NF_JourneyModels.Offer findOffer(List<NF_JourneyModels.Offer> offers, String code) {
        if (String.isBlank(code)) throw new NF_JourneyModels.JourneyException('Say which plan (use its plan code from find_plans).');
        String c = code.trim().toLowerCase();
        for (NF_JourneyModels.Offer o : offers) if (o.productCode != null && o.productCode.toLowerCase() == c) return o;
        for (NF_JourneyModels.Offer o : offers) if (o.name.toLowerCase() == c) return o;
        NF_JourneyModels.Offer match;
        for (NF_JourneyModels.Offer o : offers) {
            if (o.name.toLowerCase().contains(c)) {
                if (match != null) throw new NF_JourneyModels.JourneyException('"' + code + '" matches more than one plan. Use the plan code.');
                match = o;
            }
        }
        if (match == null) {
            throw new NF_JourneyModels.JourneyException('There is no plan "' + code + '" at this address. Use find_plans to see the plans and their codes.');
        }
        return match;
    }

    private static List<NF_JourneyModels.SelectedOption> defaultOptions(NF_JourneyModels.Offer offer) {
        List<NF_JourneyModels.SelectedOption> out = new List<NF_JourneyModels.SelectedOption>();
        for (NF_JourneyModels.OptionGroup g : offer.groups == null ? new List<NF_JourneyModels.OptionGroup>() : offer.groups) {
            for (NF_JourneyModels.Option o : g.options) {
                if (o.isDefault == true || o.isRequired == true) out.add(selection(o.componentId, o.defaultQuantity));
            }
        }
        return out;
    }

    private static NF_JourneyModels.SelectedOption selection(String componentId, Integer quantity) {
        NF_JourneyModels.SelectedOption so = new NF_JourneyModels.SelectedOption();
        so.componentId = componentId;
        so.quantity = quantity == null || quantity < 1 ? 1 : quantity;
        return so;
    }

    private static List<String> splitNames(String text) {
        List<String> out = new List<String>();
        if (String.isBlank(text)) return out;
        for (String part : text.split('[,;]')) if (String.isNotBlank(part)) out.add(part.trim());
        return out;
    }

    private static void applyAddOns(NF_JourneyModels.CartItem item, NF_JourneyModels.Offer offer,
                                    List<String> adds, List<String> removes, List<String> notes) {
        if (adds.isEmpty() && removes.isEmpty()) return;
        Map<String, Integer> chosen = new Map<String, Integer>();
        for (NF_JourneyModels.SelectedOption so : item.options) chosen.put(so.componentId, so.quantity);
        for (String name : removes) {
            NF_JourneyModels.OptionGroup g = groupOf(offer, name);
            NF_JourneyModels.Option o = optionNamed(g, name);
            if (o == null) {
                notes.add('"' + name + '" is not an option of ' + offer.name + '.');
            } else if (o.isRequired == true) {
                notes.add(o.name + ' is required with ' + offer.name + ' and stays.');
            } else {
                chosen.remove(o.componentId);
            }
        }
        for (String name : adds) {
            NF_JourneyModels.OptionGroup g = groupOf(offer, name);
            NF_JourneyModels.Option o = optionNamed(g, name);
            if (o == null) {
                notes.add('"' + name + '" is not an option of ' + offer.name + '.');
                continue;
            }
            if (g.maxOptions == 1) {
                for (NF_JourneyModels.Option other : g.options) if (other.componentId != o.componentId) chosen.remove(other.componentId);
            }
            if (!chosen.containsKey(o.componentId)) chosen.put(o.componentId, o.defaultQuantity == null || o.defaultQuantity < 1 ? 1 : o.defaultQuantity);
        }
        List<NF_JourneyModels.SelectedOption> next = new List<NF_JourneyModels.SelectedOption>();
        for (String id : chosen.keySet()) next.add(selection(id, chosen.get(id)));
        item.options = next;
    }

    private static NF_JourneyModels.OptionGroup groupOf(NF_JourneyModels.Offer offer, String name) {
        for (NF_JourneyModels.OptionGroup g : offer.groups == null ? new List<NF_JourneyModels.OptionGroup>() : offer.groups) {
            if (optionNamed(g, name) != null) return g;
        }
        return null;
    }

    private static NF_JourneyModels.Option optionNamed(NF_JourneyModels.OptionGroup g, String name) {
        if (g == null) return null;
        String n = name.toLowerCase();
        for (NF_JourneyModels.Option o : g.options) if (o.name.toLowerCase() == n) return o;
        for (NF_JourneyModels.Option o : g.options) if (o.name.toLowerCase().contains(n)) return o;
        return null;
    }

    // ── Descriptions for the agent ───────────────────────────────────────────

    public static String describeServiceability(NF_JourneyModels.ServiceabilityResult r) {
        String location = r.address == null ? '' : 'Address: ' + r.address.singleLine() + '. ';
        if (r.technologies == null || r.technologies.isEmpty()) {
            return location + 'No home internet or TV is available at this address (' + r.status + '). Mobile plans are still available.';
        }
        List<String> techs = new List<String>();
        for (NF_JourneyModels.Technology t : r.technologies) {
            techs.add(t.technology + ' up to ' + t.maxDownloadMbps + ' Mbps down / ' + t.maxUploadMbps + ' Mbps up'
                + (t.installType == null ? '' : ' (' + t.installType + (t.leadTimeDays == null ? '' : ', installation in about '
                + t.leadTimeDays + ' days') + ')'));
        }
        return location + 'Status: ' + r.status + '. Available: ' + String.join(techs, '; ') + '. TV: '
            + (r.tvAvailable == true ? 'available' : 'not available') + '.';
    }

    private static String technologyProfile(NF_JourneyModels.ServiceabilityResult r) {
        if (r.technologies == null || r.technologies.isEmpty()) return 'an address without home internet';
        List<String> techs = new List<String>();
        for (NF_JourneyModels.Technology t : r.technologies) techs.add(t.technology + ' ' + t.maxDownloadMbps + ' Mbps');
        return String.join(techs, ' + ');
    }

    private static String describeOffer(NF_JourneyModels.Offer o) {
        List<String> parts = new List<String>{ '- ' + o.name + ' [code ' + o.productCode + ']: ' + money(o.price)
            + (o.chargeType == 'One-Time' ? ' one-time' : '/month') };
        if (o.downloadMbps != null) {
            parts.add(o.downloadMbps + (o.uploadMbps == null ? '' : '/' + o.uploadMbps) + ' Mbps' + (o.technology == null ? '' : ' ' + o.technology));
        }
        if (o.highlights != null && !o.highlights.isEmpty()) parts.add(String.join(o.highlights, ', '));
        List<String> included = new List<String>();
        List<String> addOns = new List<String>();
        for (NF_JourneyModels.OptionGroup g : o.groups == null ? new List<NF_JourneyModels.OptionGroup>() : o.groups) {
            for (NF_JourneyModels.Option op : g.options) {
                String label = op.name + (op.price == null || op.price == 0 ? '' : ' ' + money(op.price) + (op.chargeType == 'One-Time' ? ' one-time' : '/month'));
                if (op.isDefault == true || op.isRequired == true) included.add(label);
                else addOns.add(label + (g.maxOptions == 1 ? ' (instead of the ' + g.name.toLowerCase() + ' default)' : ''));
            }
        }
        if (!included.isEmpty()) parts.add('includes ' + String.join(included, ', '));
        if (!addOns.isEmpty()) parts.add('optional add-ons: ' + String.join(addOns, ', '));
        return String.join(parts, ' · ');
    }

    public static String describeCart(State s) {
        if (s.priced == null) return 'Cart: ' + s.items.size() + ' plan(s), not priced yet.';
        return 'Cart, configured and priced by Revenue Cloud:\n' + describeLines(s.priced)
            + (s.priced.messages == null || s.priced.messages.isEmpty() ? '' : '\nConfigurator messages: ' + messagesText(s.priced))
            + (s.priced.hasErrors == true ? '\nThe cart has errors; it cannot be quoted until they are fixed.' : '');
    }

    private static String describeLines(NF_JourneyModels.QuoteSummary q) {
        List<String> out = new List<String>();
        Map<String, List<String>> childrenOf = new Map<String, List<String>>();
        for (NF_JourneyModels.QuoteLine l : q.lines) {
            if (l.parentLineId != null) {
                if (!childrenOf.containsKey(l.parentLineId)) childrenOf.put(l.parentLineId, new List<String>());
                childrenOf.get(l.parentLineId).add(l.productName + (l.netTotal == null || l.netTotal == 0 ? '' : ' ' + money(l.netTotal)
                    + (l.chargeType == 'One-Time' ? ' one-time' : '/month')));
            }
        }
        for (NF_JourneyModels.QuoteLine l : q.lines) {
            if (l.parentLineId != null) continue;
            String line = '- ' + l.productName + (l.quantity != null && l.quantity > 1 ? ' ×' + l.quantity.intValue() : '') + ': '
                + money(l.netTotal) + (l.chargeType == 'One-Time' ? ' one-time' : '/month');
            if (childrenOf.containsKey(l.lineId)) line += ' (with ' + String.join(childrenOf.get(l.lineId), ', ') + ')';
            out.add(line);
        }
        out.add('Total: ' + money(q.monthlyTotal) + '/month and ' + money(q.oneTimeTotal) + ' one-time, before taxes.');
        return String.join(out, '\n');
    }

    private static String messagesText(NF_JourneyModels.QuoteSummary q) {
        List<String> out = new List<String>();
        for (NF_JourneyModels.CartMessage m : q.messages) {
            out.add('[' + m.severity + '] ' + (m.productName == null ? '' : m.productName + ': ') + m.message);
        }
        return String.join(out, ' ');
    }

    private static String errorText(NF_JourneyModels.QuoteSummary q) {
        List<String> out = new List<String>();
        for (NF_JourneyModels.CartMessage m : q.messages) if (m.severity == 'error') out.add(m.message);
        return String.join(out, ' ');
    }

    public static String money(Decimal value) {
        return '$' + String.valueOf((value == null ? Decimal.valueOf(0) : value).setScale(2));
    }
}
