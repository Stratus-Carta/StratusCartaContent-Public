/**
 * NF_DroService
 * Hands a confirmed NovaFiber order to Revenue Cloud Dynamic Revenue Orchestrator (DRO).
 *  1. the order gets the service location as billing and shipping address (order activation requires them;
 *     tax and billing treatments come from the NovaFiber tax and billing policies on the products);
 *  2. the order is activated (draft orders can't be submitted to DRO);
 *  3. POST /actions/standard/submitOrder: DRO decomposes the commercial products into the NovaFiber
 *     technical products and composes the orchestration plan (4 swimlanes, see scripts/apex/nf_07_droConfig.apex).
 * All REST through the NF_RevenueCloud named credential, so it runs in the customer's transaction.
 * A failure never loses the customer's order: it is flagged "Needs Attention" for operations instead.
 */
public inherited sharing class NF_DroService {

    public class Submission {
        public Boolean submitted = false;
        public String requestId;
        public String planId;
        public String error;
    }

    /** Callouts only; call recordSubmission() afterwards to write the outcome (DML). */
    public static Submission submit(Id orderId, Id quoteId) {
        Submission s = new Submission();
        try {
            Map<String, Object> address = serviceAddress(quoteId);
            if (!address.isEmpty()) {
                NF_RevCloudApi.patch('/sobjects/Order/' + orderId, address, 'Order · service location as billing and shipping address', null);
            }
            NF_RevCloudApi.patch('/sobjects/Order/' + orderId, new Map<String, Object>{ 'Status' => 'Activated' },
                'Order · activate (required before DRO)', null);
            NF_Trace.rec('UPDATE', 'Order', orderId, 'activated');

            List<Object> results = NF_RevCloudApi.postList('/actions/standard/submitOrder', new Map<String, Object>{
                'inputs' => new List<Object>{ new Map<String, Object>{ 'orderId' => orderId, 'callType' => 'Asynchronous' } }
            }, 'Revenue Cloud DRO · submit order for decomposition and orchestration');
            Map<String, Object> result = results.isEmpty() || !(results[0] instanceof Map<String, Object>)
                ? new Map<String, Object>() : (Map<String, Object>) results[0];
            Map<String, Object> out = result.get('outputValues') instanceof Map<String, Object>
                ? (Map<String, Object>) result.get('outputValues') : new Map<String, Object>();
            String status = String.valueOf(out.get('submitStatus'));
            s.requestId = (String) out.get('requestId');
            s.planId = (String) out.get('fulfillmentPlanId');
            s.submitted = result.get('isSuccess') == true && (status == 'SUCCESS' || status == 'SUBMITTED');
            if (!s.submitted) s.error = NF_RevCloudApi.firstError(result.get('errors'));
        } catch (NF_RevCloudApi.RevCloudException e) {
            s.error = e.getMessage();
        }
        if (s.error != null) System.debug(LoggingLevel.ERROR, 'NF DRO submission failed for ' + orderId + ': ' + s.error);
        return s;
    }

    /** DML: the order's DRO stamp and its first milestone (or the fallout flag). */
    public static void recordSubmission(Id orderId, Submission s) {
        if (s.submitted) {
            update new Order(Id = orderId, NF_Submitted_To_DRO__c = DateTime.now(), NF_DRO_Request_Id__c = s.requestId);
            NF_FulfillmentStatus.apply(orderId, 'Submitted', 'Orchestrator', null, null);
        } else {
            Order o = [SELECT AccountId FROM Order WHERE Id = :orderId];
            update new Order(Id = orderId, NF_Fulfillment_Status__c = NF_FulfillmentStatus.NEEDS_ATTENTION);
            insert new NF_Fulfillment_Event__c(Order__c = orderId, Account__c = o.AccountId, System__c = 'Orchestrator',
                Event_Type__c = 'Status', Status__c = 'Failed', Customer_Visible__c = false,
                Message__c = ('Submission to DRO failed: ' + s.error).left(255));
        }
    }

    private static Map<String, Object> serviceAddress(Id quoteId) {
        List<QuoteLineItemRecipient> rs = quoteId == null ? new List<QuoteLineItemRecipient>() : [
            SELECT ServiceStreet, ServiceCity, ServiceState, ServicePostalCode, ServiceCountry
            FROM QuoteLineItemRecipient WHERE QuoteId = :quoteId ORDER BY CreatedDate ASC LIMIT 1
        ];
        if (rs.isEmpty() || String.isBlank(rs[0].ServicePostalCode)) return new Map<String, Object>();
        QuoteLineItemRecipient r = rs[0];
        Map<String, Object> m = new Map<String, Object>();
        for (String prefix : new List<String>{ 'Billing', 'Shipping' }) {
            m.put(prefix + 'Street', r.ServiceStreet);
            m.put(prefix + 'City', r.ServiceCity);
            m.put(prefix + 'State', r.ServiceState);
            m.put(prefix + 'PostalCode', r.ServicePostalCode);
            m.put(prefix + 'Country', String.isBlank(r.ServiceCountry) ? 'US' : r.ServiceCountry);
        }
        return m;
    }
}
