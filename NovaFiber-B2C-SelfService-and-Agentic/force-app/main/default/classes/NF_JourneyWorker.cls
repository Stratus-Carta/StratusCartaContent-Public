/**
 * NF_JourneyWorker
 * Runs the order step for guest self-service visitors, who cannot run createOrderFromQuote.
 * (The cart and quote no longer need it: they run as Revenue Cloud REST calls through the
 * NF_RevenueCloud named credential, see NF_QuoteService.)
 *
 *   guest transaction   : validate → enqueue() → NF_Journey_Request__c (Pending)
 *                         + NF_Journey_Signal__e (published after commit)
 *   event trigger       : process() runs as the PlatformEventSubscriberConfig user (NF_JourneyWorkerConfig),
 *                         who has Revenue Cloud access → order from quote → Completed | Failed
 *   browser             : polls NF_JourneyController.getRequestResult(requestKey)
 *
 * Payloads are built server side in the guest transaction; the browser only ever holds the request key.
 * When the inspector is on, the worker's own NF_Trace is stored on the request and returned by poll().
 */
public without sharing class NF_JourneyWorker {

    public static final String OP_SUBMIT_ORDER = 'SUBMIT_ORDER';

    public class OrderPayload {
        public String quoteId;
        public NF_JourneyModels.CustomerDetails customer;
        public NF_JourneyModels.JourneyContext ctx;
    }

    public class RequestResult {
        @AuraEnabled public String status;      // Pending | Completed | Failed
        @AuraEnabled public String resultJson;
        @AuraEnabled public String error;
        @AuraEnabled public String requestName;
    }

    /** Stores the payload and signals the worker. Returns the key the browser polls with. */
    public static String enqueue(String operation, Object payload) {
        String key = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        NF_Journey_Request__c r = new NF_Journey_Request__c(
            Request_Key__c = key, Operation__c = operation, Status__c = 'Pending',
            Payload__c = JSON.serialize(payload), Trace_Enabled__c = NF_Trace.isEnabled());
        insert r;
        NF_Trace.dml('INSERT', new List<SObject>{ r }, operation + ' queued for the worker');
        EventBus.publish(new NF_Journey_Signal__e(Request_Id__c = r.Id));
        NF_Trace.note('EVENT', 'publish NF_Journey_Signal__e', 'after commit → NF_JourneyRequestTrigger');
        return key;
    }

    public static RequestResult poll(String key) {
        List<NF_Journey_Request__c> rs = [
            SELECT Name, Status__c, Result__c, Error__c, Trace__c
            FROM NF_Journey_Request__c WHERE Request_Key__c = :key LIMIT 1
        ];
        if (rs.isEmpty()) throw new NF_JourneyModels.JourneyException('Your session expired. Please start again.');
        RequestResult out = new RequestResult();
        out.status = rs[0].Status__c;
        out.resultJson = rs[0].Result__c;
        out.error = rs[0].Error__c;
        out.requestName = rs[0].Name;
        if (out.status != 'Pending' && String.isNotBlank(rs[0].Trace__c)) {
            NF_Trace.absorb((List<NF_Trace.Entry>) JSON.deserialize(rs[0].Trace__c, List<NF_Trace.Entry>.class));
        }
        return out;
    }

    public static void process(List<NF_Journey_Signal__e> events) {
        Set<Id> ids = new Set<Id>();
        for (NF_Journey_Signal__e e : events) ids.add(e.Request_Id__c);
        for (NF_Journey_Request__c r : [
            SELECT Id, Name, Operation__c, Payload__c, Trace_Enabled__c, CreatedDate
            FROM NF_Journey_Request__c WHERE Id IN :ids AND Status__c = 'Pending'
        ]) {
            processOne(r);
        }
    }

    private static void processOne(NF_Journey_Request__c r) {
        if (r.Trace_Enabled__c) NF_Trace.enable();
        NF_Trace.Entry w = NF_Trace.start('WORKER', 'NF_JourneyWorker · ' + r.Operation__c,
            r.Name + ' · runs as ' + UserInfo.getUserName() + ' · picked up '
            + (DateTime.now().getTime() - r.CreatedDate.getTime()) + ' ms after queueing');
        Savepoint sp = Database.setSavepoint();
        try {
            Object result;
            if (r.Operation__c == OP_SUBMIT_ORDER) {
                OrderPayload p = (OrderPayload) JSON.deserialize(r.Payload__c, OrderPayload.class);
                result = NF_OrderService.submit(p.quoteId, p.customer, p.ctx);
            }
            r.Result__c = JSON.serialize(result);
            r.Status__c = 'Completed';
            NF_Trace.end(w, 'OK', null);
        } catch (Exception e) {
            Database.rollback(sp);
            r.Status__c = 'Failed';
            r.Error__c = (e instanceof NF_JourneyModels.JourneyException
                ? e.getMessage() : 'Something went wrong. Please try again.').left(255);
            r.Error_Detail__c = (e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString()).left(32768);
            NF_Trace.end(w, 'ERROR', e.getTypeName() + ': ' + e.getMessage());
        }
        if (r.Trace_Enabled__c) r.Trace__c = fitTrace(NF_Trace.drain());
        update r;
    }

    /** Keeps the stored trace valid JSON within the field size by dropping payload bodies if needed. */
    private static String fitTrace(List<NF_Trace.Entry> trace) {
        String s = JSON.serialize(trace);
        if (s.length() <= 131072) return s;
        for (NF_Trace.Entry e : trace) {
            e.requestJson = e.requestJson == null ? null : '(omitted: trace too large)';
            e.responseJson = e.responseJson == null ? null : '(omitted: trace too large)';
        }
        s = JSON.serialize(trace);
        return s.length() <= 131072 ? s : null;
    }
}
