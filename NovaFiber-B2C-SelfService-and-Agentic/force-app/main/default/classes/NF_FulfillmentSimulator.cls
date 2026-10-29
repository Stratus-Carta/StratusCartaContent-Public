/**
 * NF_FulfillmentSimulator
 * Plays the mock Provisioning, Logistics and Billing systems after they accepted a request (HTTP 202):
 * a delayed queueable that sends the system's callback over HTTP to this org's
 * NF_FulfillmentCallbackApi (through the NF_RevenueCloud named credential, as the integration user),
 * exactly like the real system would call the DRO callback URI.
 */
public without sharing class NF_FulfillmentSimulator implements Queueable, Database.AllowsCallouts {

    public static final Integer MAX_ATTEMPTS = 6;
    private final Id eventId;
    private final Integer attempt;

    public NF_FulfillmentSimulator(Id eventId, Integer attempt) {
        this.eventId = eventId;
        this.attempt = attempt;
    }

    /** Queues the callback for an event, after the given delay (0-10 minutes). */
    public static void schedule(Id eventId, Integer delayMinutes) {
        Integer delay = Math.max(0, Math.min(10, delayMinutes == null ? 1 : delayMinutes));
        if (Test.isRunningTest()) delay = 0;
        System.enqueueJob(new NF_FulfillmentSimulator(eventId, 1), delay);
    }

    public void execute(QueueableContext qc) {
        NF_Fulfillment_Event__c ev = [
            SELECT Id, Step_Id__c, System__c, Callback_Event__c, External_Ref__c, Status__c
            FROM NF_Fulfillment_Event__c WHERE Id = :eventId
        ];
        if (ev.Status__c != 'Pending') return;
        Map<String, Object> callback = new Map<String, Object>{
            'eventId' => ev.Id, 'stepId' => ev.Step_Id__c, 'system' => ev.System__c,
            'event' => ev.Callback_Event__c, 'externalRef' => ev.External_Ref__c, 'status' => 'SUCCESS'
        };
        String outcome;
        String failure;
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:NF_RevenueCloud' + NF_DroCalloutProvider.CALLBACK_PATH);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(60000);
        req.setBody(JSON.serialize(callback));
        try {
            HttpResponse res = new Http().send(req);
            Map<String, Object> body = res.getStatusCode() == 200 && String.isNotBlank(res.getBody())
                ? (Map<String, Object>) JSON.deserializeUntyped(res.getBody()) : new Map<String, Object>();
            outcome = String.valueOf(body.get('outcome'));
            if (res.getStatusCode() != 200) failure = 'HTTP ' + res.getStatusCode() + ' ' + res.getBody();
        } catch (Exception e) {
            failure = e.getMessage();
        }
        if (outcome == 'RETRY' && attempt < MAX_ATTEMPTS) {
            // the step the callback completes hasn't started yet (e.g. delivery before the pause step)
            if (!Test.isRunningTest()) System.enqueueJob(new NF_FulfillmentSimulator(eventId, attempt + 1), 1);
        } else if (failure != null || outcome == 'RETRY') {
            update new NF_Fulfillment_Event__c(Id = ev.Id, Status__c = 'Failed',
                Message__c = ('Callback failed: ' + (failure == null ? 'step never became ready' : failure)).left(255));
        }
    }
}
