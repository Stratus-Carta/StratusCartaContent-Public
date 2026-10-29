/**
 * NF_PortalController
 * "My NovaFiber" customer portal on the NovaFiber site: login (NF_PortalService), and the dashboard of the
 * logged-in customer's account: service status, billing account and each order's journey through the DRO
 * orchestration (milestones from NF_FulfillmentStatus, timeline from NF_Fulfillment_Event__c, technician visit
 * from the plan's manual task). Runs without sharing for site guests; every query is scoped to the account of
 * the session token.
 */
public without sharing class NF_PortalController {

    private static final Map<String, String> LABELS = new Map<String, String>{
        'Submitted' => 'Order received', 'Order Confirmed' => 'Order confirmed', 'Network Reserved' => 'Network reserved',
        'Equipment Shipped' => 'Equipment shipped', 'Equipment Delivered' => 'Equipment delivered',
        'Installation Scheduled' => 'Technician visit scheduled', 'Installation Complete' => 'Installed',
        'Service Active' => 'Service live', 'Billing Started' => 'Billing started', 'Active' => 'All set'
    };

    public class Milestone {
        public String key;
        public String label;
        public String state;      // done | current | upcoming | attention
        public DateTime at;
        public String description;
    }

    public class TimelineEntry {
        public DateTime at;
        public String text;
        public String source;
    }

    public class OrderView {
        public String orderNumber;
        public Date placedOn;
        public String status;
        public String fulfillmentStatus;
        public String fulfillmentText;
        public Boolean complete = false;
        public Boolean needsAttention = false;
        public Decimal monthlyTotal;
        public Decimal oneTimeTotal;
        public List<NF_JourneyModels.QuoteLine> lines = new List<NF_JourneyModels.QuoteLine>();
        public List<Milestone> milestones = new List<Milestone>();
        public List<TimelineEntry> timeline = new List<TimelineEntry>();
        public String technicianVisit;   // Not scheduled | Scheduled | In progress | Completed
        public String installDateNote;
    }

    public class Dashboard {
        public String username;
        public String customerName;
        public String firstName;
        public String serviceStatus;
        public String serviceStatusText;
        public String billingAccountNumber;
        public String serviceAddress;
        public List<OrderView> orders = new List<OrderView>();
        public Boolean inProgress = false;
    }

    public class LoginResult {
        public String token;
        public Dashboard dashboard;
    }

    private interface Op {
        Object run();
    }

    // ── Entry points ─────────────────────────────────────────────────────────

    @AuraEnabled
    public static NF_JourneyModels.Envelope login(String username, String password, Boolean debug) {
        return execute('login', debug, new LoginOp(username, password));
    }

    @AuraEnabled
    public static NF_JourneyModels.Envelope getDashboard(String token, Boolean debug) {
        return execute('getDashboard', debug, new DashboardOp(token));
    }

    @AuraEnabled
    public static NF_JourneyModels.Envelope logout(String token, Boolean debug) {
        return execute('logout', debug, new LogoutOp(token));
    }

    private class LoginOp implements Op {
        String username;
        String password;
        LoginOp(String username, String password) { this.username = username; this.password = password; }
        public Object run() {
            NF_PortalService.Session s = NF_PortalService.login(username, password);
            LoginResult r = new LoginResult();
            r.token = s.token;
            r.dashboard = dashboard(s.user.Username__c, s.user.Account__c, s.user.Contact__c);
            return r;
        }
    }

    private class DashboardOp implements Op {
        String token;
        DashboardOp(String token) { this.token = token; }
        public Object run() {
            NF_Portal_User__c u = NF_PortalService.resolve(token);
            return dashboard(u.Username__c, u.Account__c, u.Contact__c);
        }
    }

    private class LogoutOp implements Op {
        String token;
        LogoutOp(String token) { this.token = token; }
        public Object run() {
            NF_PortalService.logout(token);
            return new Map<String, Object>{ 'loggedOut' => true };
        }
    }

    // ── Dashboard ────────────────────────────────────────────────────────────

    @TestVisible
    private static Dashboard dashboard(String username, Id accountId, Id contactId) {
        Dashboard d = new Dashboard();
        d.username = username;
        if (accountId == null) return d;
        Account a = [SELECT Name, NF_Service_Status__c, NF_Billing_Account_Number__c, ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode
                     FROM Account WHERE Id = :accountId];
        d.customerName = a.Name;
        if (contactId != null) d.firstName = [SELECT FirstName FROM Contact WHERE Id = :contactId].FirstName;
        d.serviceStatus = a.NF_Service_Status__c;
        d.serviceStatusText = NF_FulfillmentStatus.customerText(a.NF_Service_Status__c);
        d.billingAccountNumber = a.NF_Billing_Account_Number__c;
        d.serviceAddress = String.join(new List<String>{ a.ShippingStreet, a.ShippingCity, a.ShippingState, a.ShippingPostalCode }, ', ')
            .replace('null, ', '').removeEnd(', null');

        List<Order> orders = [
            SELECT Id, OrderNumber, Status, EffectiveDate, CreatedDate, QuoteId, Description, NF_Fulfillment_Status__c,
                   (SELECT Product2.ProductCode FROM OrderItems)
            FROM Order WHERE AccountId = :accountId AND NF_Channel__c != null ORDER BY CreatedDate DESC LIMIT 10
        ];
        Map<Id, List<NF_Fulfillment_Event__c>> eventsByOrder = new Map<Id, List<NF_Fulfillment_Event__c>>();
        for (NF_Fulfillment_Event__c e : [
                SELECT Order__c, System__c, Milestone__c, Message__c, CreatedDate FROM NF_Fulfillment_Event__c
                WHERE Order__c IN :orders AND Customer_Visible__c = true ORDER BY CreatedDate ASC, Name ASC]) {
            if (!eventsByOrder.containsKey(e.Order__c)) eventsByOrder.put(e.Order__c, new List<NF_Fulfillment_Event__c>());
            eventsByOrder.get(e.Order__c).add(e);
        }
        Map<String, String> technicianByOrder = technicianVisits(orders);
        for (Order o : orders) {
            OrderView v = orderView(o, eventsByOrder.containsKey(o.Id) ? eventsByOrder.get(o.Id) : new List<NF_Fulfillment_Event__c>());
            v.technicianVisit = technicianByOrder.get(o.Id);
            if (!v.complete) d.inProgress = true;
            d.orders.add(v);
        }
        return d;
    }

    private static OrderView orderView(Order o, List<NF_Fulfillment_Event__c> events) {
        OrderView v = new OrderView();
        v.orderNumber = o.OrderNumber;
        v.placedOn = o.CreatedDate.date();
        v.status = o.Status;
        v.fulfillmentStatus = o.NF_Fulfillment_Status__c;
        v.fulfillmentText = NF_FulfillmentStatus.customerText(o.NF_Fulfillment_Status__c);
        v.complete = o.NF_Fulfillment_Status__c == 'Active';
        v.needsAttention = o.NF_Fulfillment_Status__c == NF_FulfillmentStatus.NEEDS_ATTENTION;
        v.installDateNote = o.Description == null ? null : o.Description.substringBefore('\n');
        if (o.QuoteId != null) {
            NF_JourneyModels.QuoteSummary q = NF_QuoteService.summarize(o.QuoteId);
            v.monthlyTotal = q.monthlyTotal;
            v.oneTimeTotal = q.oneTimeTotal;
            v.lines = q.lines;
        }

        Map<String, DateTime> reached = new Map<String, DateTime>();
        for (NF_Fulfillment_Event__c e : events) {
            if (e.Milestone__c != null && !reached.containsKey(e.Milestone__c)) reached.put(e.Milestone__c, e.CreatedDate);
            TimelineEntry t = new TimelineEntry();
            t.at = e.CreatedDate;
            t.text = e.Message__c;
            t.source = e.System__c;
            v.timeline.add(t);
        }
        List<TimelineEntry> newestFirst = new List<TimelineEntry>();
        for (Integer i = v.timeline.size() - 1; i >= 0; i--) newestFirst.add(v.timeline[i]);
        v.timeline = newestFirst;

        Integer current = NF_FulfillmentStatus.rank(o.NF_Fulfillment_Status__c);
        if (v.needsAttention) {
            for (String m : reached.keySet()) current = Math.max(current, NF_FulfillmentStatus.rank(m));
        }
        for (String key : milestonesFor(o)) {
            Milestone m = new Milestone();
            m.key = key;
            m.label = LABELS.get(key);
            m.description = NF_FulfillmentStatus.customerText(key);
            m.at = reached.get(key);
            Integer r = NF_FulfillmentStatus.rank(key);
            m.state = r < current || (r == current && v.complete) ? 'done' : r == current ? (v.needsAttention ? 'attention' : 'current') : 'upcoming';
            if (m.state == 'upcoming' && m.at != null) m.state = 'done';
            v.milestones.add(m);
        }
        return v;
    }

    /** The milestones that apply to what was ordered. */
    private static List<String> milestonesFor(Order o) {
        Boolean internet = false;
        Boolean tv = false;
        for (OrderItem oi : o.OrderItems) {
            String code = oi.Product2.ProductCode == null ? '' : oi.Product2.ProductCode;
            if (code.startsWith('NFR-INT-')) internet = true;
            if (code.startsWith('NFR-TV-')) tv = true;
        }
        if (internet) return NF_FulfillmentStatus.MILESTONES;
        if (tv) {
            return new List<String>{ 'Submitted', 'Order Confirmed', 'Equipment Shipped', 'Equipment Delivered',
                'Installation Scheduled', 'Installation Complete', 'Billing Started', 'Active' };
        }
        return new List<String>{ 'Submitted', 'Order Confirmed', 'Billing Started', 'Active' };
    }

    /** The technician visit = the plan's manual task. */
    private static Map<String, String> technicianVisits(List<Order> orders) {
        Map<String, String> out = new Map<String, String>();
        Set<String> sources = new Set<String>();
        for (Order o : orders) sources.add(o.Id);
        for (FulfillmentStep s : [SELECT State, FulfillmentPlan.SourceIdentifier FROM FulfillmentStep
                                  WHERE StepType = 'ManualTask' AND FulfillmentPlan.SourceIdentifier IN :sources]) {
            String label = s.State == 'Completed' ? 'Completed' : s.State == 'InProgress' || s.State == 'Ready' ? 'Scheduled' : 'Not scheduled yet';
            out.put(s.FulfillmentPlan.SourceIdentifier.left(15), label);
        }
        Map<String, String> byOrder = new Map<String, String>();
        for (Order o : orders) {
            String k = String.valueOf(o.Id).left(15);
            if (out.containsKey(k)) byOrder.put(o.Id, out.get(k));
        }
        return byOrder;
    }

    // ── Envelope ─────────────────────────────────────────────────────────────

    private static NF_JourneyModels.Envelope execute(String name, Boolean debug, Op op) {
        Long started = DateTime.now().getTime();
        NF_JourneyModels.JourneyContext ctx = NF_JourneyController.getContext();
        Boolean tracing = debug == true && ctx.inspectorAllowed == true;
        if (tracing) NF_Trace.enable();
        NF_JourneyModels.Envelope env = new NF_JourneyModels.Envelope();
        NF_Trace.Entry root = NF_Trace.start('APEX', 'NF_PortalController.' + name + '()', 'My NovaFiber portal');
        try {
            env.dataJson = JSON.serialize(op.run());
            NF_Trace.end(root, 'OK', null);
        } catch (Exception e) {
            env.error = e instanceof NF_JourneyModels.JourneyException ? e.getMessage() : 'Something went wrong. Please try again.';
            NF_Trace.end(root, 'ERROR', e.getTypeName() + ': ' + e.getMessage());
            if (!(e instanceof NF_JourneyModels.JourneyException)) {
                System.debug(LoggingLevel.ERROR, 'NF portal error: ' + e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
            }
        }
        if (tracing) {
            env.trace = NF_Trace.drain();
            env.limits = NF_Trace.limitsSnapshot();
        }
        env.serverMs = Integer.valueOf(DateTime.now().getTime() - started);
        return env;
    }
}
