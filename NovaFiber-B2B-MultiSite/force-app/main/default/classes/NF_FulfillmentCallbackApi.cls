/**
 * NF_FulfillmentCallbackApi
 * Callback URI of the NovaFiber DRO callout steps: POST /services/apexrest/nf/fulfillment/v1/callback
 * { eventId, stepId, system, event, externalRef, status }. Called by the (mock) Provisioning, Logistics and
 * Billing systems after an asynchronous request; here NF_FulfillmentSimulator plays them.
 *
 * Completes the waiting Fulfillment Step so DRO moves the plan on, records the callback and moves the
 * customer's milestone where the callback itself is the milestone (shipped, delivered). Logistics also
 * owes a second event: SHIPPED schedules DELIVERED, which resumes the plan's Pause step
 * "Awaiting equipment delivery".
 */
@RestResource(urlMapping='/nf/fulfillment/v1/callback')
global without sharing class NF_FulfillmentCallbackApi {

    public static final String DELIVERY_PAUSE_STEP = 'Awaiting equipment delivery';
    private static final Set<String> WAITING = new Set<String>{ 'InProgress', 'Running' };

    @HttpPost
    global static void receive() {
        RestResponse res = RestContext.response;
        Map<String, Object> result;
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(RestContext.request.requestBody.toString());
            result = process(body);
            res.statusCode = result.get('outcome') == 'NOT_FOUND' ? 404 : 200;
        } catch (Exception e) {
            res.statusCode = 400;
            result = new Map<String, Object>{ 'outcome' => 'ERROR', 'message' => e.getMessage() };
        }
        res.addHeader('Content-Type', 'application/json');
        res.responseBody = Blob.valueOf(JSON.serialize(result));
    }

    /** Outcome: COMPLETED, RETRY (target step not waiting yet), ALREADY_DONE or NOT_FOUND. */
    public static Map<String, Object> process(Map<String, Object> body) {
        String stepId = (String) body.get('stepId');
        String sourceSystem = (String) body.get('system');
        String event = (String) body.get('event');
        String externalRef = (String) body.get('externalRef');
        Id eventId = body.get('eventId') == null ? null : (Id) String.valueOf(body.get('eventId'));
        Boolean success = body.get('status') == null || body.get('status') == 'SUCCESS';

        List<FulfillmentStep> steps = String.isBlank(stepId) ? new List<FulfillmentStep>() : [
            SELECT Id, Name, State, StepType, FulfillmentPlanId, FulfillmentPlan.SourceIdentifier FROM FulfillmentStep WHERE Id = :stepId LIMIT 1
        ];
        if (steps.isEmpty()) return new Map<String, Object>{ 'outcome' => 'NOT_FOUND' };
        FulfillmentStep step = steps[0];
        Boolean alreadyDone = step.State == 'Completed' || step.State == 'Skipped';
        if (!alreadyDone && !WAITING.contains(step.State)) return new Map<String, Object>{ 'outcome' => 'RETRY', 'state' => step.State };

        if (!alreadyDone) update new FulfillmentStep(Id = step.Id, State = success ? 'Completed' : 'Failed');
        closeEvent(eventId, success || alreadyDone ? 'Completed' : 'Failed');
        Id orderId = orderOf(step);
        Order o = orderId == null ? null : [SELECT Id, AccountId FROM Order WHERE Id = :orderId];
        if (alreadyDone) {
            // the plan moved on without waiting (e.g. the pause elapsed): the customer milestone still happened
            // (a repeated SHIPPED callback must not schedule a second delivery)
            if (success && o != null && event != 'SHIPPED') applyMilestone(event, o, step, externalRef);
            return new Map<String, Object>{ 'outcome' => 'ALREADY_DONE' };
        }
        insert new NF_Fulfillment_Event__c(Order__c = o?.Id, Account__c = o?.AccountId, Step_Id__c = step.Id,
            Step_Name__c = step.Name, System__c = sourceSystem, Event_Type__c = 'Callback', Status__c = success ? 'Completed' : 'Failed',
            Callback_Event__c = event, External_Ref__c = externalRef, Customer_Visible__c = false,
            Message__c = (sourceSystem + ' callback ' + event + (externalRef == null ? '' : ' · ' + externalRef) + ' → ' + step.Name
                + (success ? ' completed' : ' failed')).left(255));

        if (success && o != null) {
            applyMilestone(event, o, step, externalRef);
        } else if (!success && o != null) {
            update new Order(Id = o.Id, NF_Fulfillment_Status__c = NF_FulfillmentStatus.NEEDS_ATTENTION);
        }
        return new Map<String, Object>{ 'outcome' => 'COMPLETED', 'step' => step.Name };
    }

    /** Callbacks that are themselves customer milestones. */
    private static void applyMilestone(String event, Order o, FulfillmentStep step, String externalRef) {
        if (event == 'SHIPPED') {
            NF_FulfillmentStatus.apply(o.Id, 'Equipment Shipped', 'Logistics',
                'Your equipment is on its way' + (externalRef == null ? '.' : ' (tracking ' + externalRef + ').'), step.Id);
            scheduleDelivery(step, o, externalRef);
        } else if (event == 'DELIVERED') {
            NF_FulfillmentStatus.apply(o.Id, 'Equipment Delivered', 'Logistics', null, step.Id);
        } else if (event == 'BILLING_STARTED') {
            NF_FulfillmentStatus.apply(o.Id, 'Billing Started', 'Billing', null, step.Id);
        }
    }

    /** NovaShip delivers ~3 minutes after shipping (the Pause step's transit delay); the delivery resumes the Pause step. */
    private static void scheduleDelivery(FulfillmentStep shipStep, Order o, String trackingNumber) {
        List<FulfillmentStep> pauses = [
            SELECT Id, Name FROM FulfillmentStep
            WHERE FulfillmentPlanId = :shipStep.FulfillmentPlanId AND StepType = 'Pause' AND Name = :DELIVERY_PAUSE_STEP LIMIT 1
        ];
        if (pauses.isEmpty()) return;
        NF_Fulfillment_Event__c ev = new NF_Fulfillment_Event__c(Order__c = o.Id, Account__c = o.AccountId, Step_Id__c = pauses[0].Id,
            Step_Name__c = pauses[0].Name, System__c = 'Logistics', Event_Type__c = 'Callout', Status__c = 'Pending',
            Callback_Event__c = 'DELIVERED', External_Ref__c = trackingNumber, Due_At__c = DateTime.now().addMinutes(3),
            Customer_Visible__c = false, Message__c = 'NovaShip delivery confirmation expected');
        insert ev;
        NF_FulfillmentSimulator.schedule(ev.Id, 3);
    }

    private static Id orderOf(FulfillmentStep step) {
        String source = step.FulfillmentPlan?.SourceIdentifier;
        try {
            Id sid = String.isBlank(source) ? null : Id.valueOf(source);
            return sid != null && sid.getSObjectType() == Order.SObjectType ? sid : null;
        } catch (Exception e) {
            return null;
        }
    }

    private static void closeEvent(Id eventId, String status) {
        if (eventId != null) update new NF_Fulfillment_Event__c(Id = eventId, Status__c = status);
    }
}
