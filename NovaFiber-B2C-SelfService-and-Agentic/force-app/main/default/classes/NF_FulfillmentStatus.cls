/**
 * NF_FulfillmentStatus
 * Customer-facing fulfillment milestones of a NovaFiber order. The DRO orchestration plan moves the order
 * forward through AutoTask steps (flows NF_DRO_*) after each milestone and through the mock systems'
 * callbacks (NF_FulfillmentCallbackApi). Each move updates Order.NF_Fulfillment_Status__c,
 * Account.NF_Service_Status__c and writes an NF_Fulfillment_Event__c for the customer portal timeline.
 * Status never moves backwards (a late callback can't undo a later milestone).
 */
public without sharing class NF_FulfillmentStatus {

    public static final List<String> MILESTONES = new List<String>{
        'Submitted', 'Order Confirmed', 'Network Reserved', 'Equipment Shipped', 'Equipment Delivered',
        'Installation Scheduled', 'Installation Complete', 'Service Active', 'Billing Started', 'Active'
    };
    public static final String NEEDS_ATTENTION = 'Needs Attention';

    private static final Map<String, String> CUSTOMER_TEXT = new Map<String, String>{
        'Submitted' => 'We received your order and sent it to fulfillment.',
        'Order Confirmed' => 'Your order is confirmed and your service is being set up.',
        'Network Reserved' => 'A connection on the NovaNet network is reserved for your address.',
        'Equipment Shipped' => 'Your equipment is on its way.',
        'Equipment Delivered' => 'Your equipment was delivered.',
        'Installation Scheduled' => 'A technician visit is being scheduled.',
        'Installation Complete' => 'Installation is complete.',
        'Service Active' => 'Your NovaFiber service is live.',
        'Billing Started' => 'Your billing account is active; your first bill is on its way.',
        'Active' => 'All set: your NovaFiber services are active.'
    };

    public static Integer rank(String milestone) {
        return MILESTONES.indexOf(milestone);
    }

    public static String customerText(String milestone) {
        return CUSTOMER_TEXT.containsKey(milestone) ? CUSTOMER_TEXT.get(milestone) : milestone;
    }

    /** Moves the order (and its account) to a milestone if it is further along; returns true when it moved. */
    public static Boolean apply(Id orderId, String milestone, String sourceSystem, String message, String stepId) {
        if (orderId == null || rank(milestone) < 0) return false;
        Order o = [SELECT Id, AccountId, NF_Fulfillment_Status__c, Account.NF_Service_Status__c FROM Order WHERE Id = :orderId];
        Boolean moved = rank(milestone) > rank(o.NF_Fulfillment_Status__c);
        if (moved) {
            update new Order(Id = o.Id, NF_Fulfillment_Status__c = milestone);
            if (o.AccountId != null && rank(milestone) > rank(o.Account.NF_Service_Status__c)) {
                update new Account(Id = o.AccountId, NF_Service_Status__c = milestone);
            }
        }
        insert new NF_Fulfillment_Event__c(Order__c = o.Id, Account__c = o.AccountId, System__c = sourceSystem == null ? 'Orchestrator' : sourceSystem,
            Event_Type__c = 'Milestone', Status__c = 'Completed', Milestone__c = milestone, Step_Id__c = stepId,
            Message__c = (String.isBlank(message) ? customerText(milestone) : message).left(255), Customer_Visible__c = true);
        return moved;
    }

    // ── AutoTask flows ───────────────────────────────────────────────────────

    public class Request {
        @InvocableVariable(required=true label='Order Id' description='planSourceIdentifierId of the DRO plan (the order).')
        public String orderId;
        @InvocableVariable(label='Milestone' description='Customer milestone, e.g. Order Confirmed. Empty: only validate.')
        public String milestone;
        @InvocableVariable(label='Message' description='Optional customer-readable text for the timeline.')
        public String message;
    }

    /** Called by the AutoTask flows of the NovaFiber orchestration plan. */
    @InvocableMethod(label='NovaFiber: Set Fulfillment Milestone' description='Moves a NovaFiber order and its customer account to a fulfillment milestone and records it on the portal timeline. Without a milestone it validates the order for fulfillment.' category='NovaFiber')
    public static void setMilestone(List<Request> requests) {
        for (Request r : requests) {
            Id orderId = (Id) r.orderId;
            if (String.isBlank(r.milestone)) {
                validate(orderId);
            } else {
                apply(orderId, r.milestone, 'Orchestrator', r.message, null);
            }
        }
    }

    /** Order intake checks: an activated order with items, a customer and a service address. */
    private static void validate(Id orderId) {
        Order o = [SELECT Id, AccountId, Status, ShippingPostalCode, (SELECT Id FROM OrderItems LIMIT 1) FROM Order WHERE Id = :orderId];
        List<String> problems = new List<String>();
        if (o.Status != 'Activated') problems.add('order is not activated');
        if (o.OrderItems.isEmpty()) problems.add('order has no items');
        if (o.AccountId == null) problems.add('order has no customer');
        if (String.isBlank(o.ShippingPostalCode)) problems.add('order has no service address');
        insert new NF_Fulfillment_Event__c(Order__c = o.Id, Account__c = o.AccountId, System__c = 'Orchestrator', Event_Type__c = 'Task',
            Status__c = problems.isEmpty() ? 'Completed' : 'Failed', Customer_Visible__c = false,
            Message__c = (problems.isEmpty() ? 'Order validated for fulfillment' : 'Validation failed: ' + String.join(problems, ', ')).left(255));
        if (!problems.isEmpty()) {
            update new Order(Id = o.Id, NF_Fulfillment_Status__c = NEEDS_ATTENTION);
            throw new NF_JourneyModels.JourneyException('Order validation failed: ' + String.join(problems, ', '));
        }
    }
}
