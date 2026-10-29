/**
 * NF_DroCalloutProvider
 * DRO "Apex Type Provider" for the NovaFiber orchestration plan's Callout steps. One provider serves the
 * mock NovaNet Provisioning, NovaShip Logistics and NovaBill Billing systems (Postman mock behind the
 * NF_FulfillmentSystems named credential); each Integration Definition (NF_Provisioning_Reserve, ...)
 * sets the system, path and the callback it expects through provider attributes.
 *
 * Asynchronous interaction pattern: when the system answers 202 Accepted the step stays In Progress and an
 * NF_Fulfillment_Event__c records the callback still owed. NF_FulfillmentSimulator plays the external system
 * and calls NF_FulfillmentCallbackApi later, which completes the step. 200/201 completes the step at once.
 */
global without sharing class NF_DroCalloutProvider implements industriesintegrationfwk.ProcessIntegrationProvider {

    public static final String CALLBACK_PATH = '/services/apexrest/nf/fulfillment/v1/callback';
    private static final Integer TIMEOUT_MS = 20000;

    private static final industriesintegrationfwk.ApexProviderAttr SYSTEM_ATTR = new industriesintegrationfwk.ApexProviderAttr(
        'System', 'NF_System', 'Provisioning', true, 'String');
    private static final industriesintegrationfwk.ApexProviderAttr PATH_ATTR = new industriesintegrationfwk.ApexProviderAttr(
        'Path', 'NF_Path', '/provisioning/v1/reservations', true, 'String');
    private static final industriesintegrationfwk.ApexProviderAttr STEP_ATTR = new industriesintegrationfwk.ApexProviderAttr(
        'Step Name', 'NF_Step_Name', '', false, 'String');
    private static final industriesintegrationfwk.ApexProviderAttr CALLBACK_EVENT_ATTR = new industriesintegrationfwk.ApexProviderAttr(
        'Callback Event', 'NF_Callback_Event', '', false, 'String');
    private static final industriesintegrationfwk.ApexProviderAttr CALLBACK_DELAY_ATTR = new industriesintegrationfwk.ApexProviderAttr(
        'Callback Delay Minutes', 'NF_Callback_Delay_Minutes', '1', false, 'String');
    private static final industriesintegrationfwk.ApexProviderAttr CALLBACK_URL_ATTR = new industriesintegrationfwk.ApexProviderAttr(
        'Callback URL', 'Callback_URL', CALLBACK_PATH, false, 'String');

    @TestVisible private static Integer simulatedDelayOverride;

    global List<industriesintegrationfwk.ApexProviderAttr> getProviderAttributes() {
        return new List<industriesintegrationfwk.ApexProviderAttr>{
            SYSTEM_ATTR, PATH_ATTR, STEP_ATTR, CALLBACK_EVENT_ATTR, CALLBACK_DELAY_ATTR, CALLBACK_URL_ATTR };
    }

    global industriesintegrationfwk.IntegrationCalloutResponse executeCallout(String requestGuid, String inputRecordId,
                                                                              String payload, Map<String, Object> attributes) {
        Map<String, Object> attrs = attributes == null ? new Map<String, Object>() : attributes;
        String sourceSystem = text(attrs, 'NF_System', 'Provisioning');
        String path = text(attrs, 'NF_Path', '');
        String stepName = text(attrs, 'NF_Step_Name', '');
        String callbackEvent = text(attrs, 'NF_Callback_Event', '');
        Integer delay = Integer.valueOf(text(attrs, 'NF_Callback_Delay_Minutes', '1'));

        Order o = orderOf(inputRecordId);
        String stepId = stepIdOf(requestGuid, payload, inputRecordId, stepName);
        Map<String, Object> body = requestBody(o, stepId, stepName);

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:NF_FulfillmentSystems' + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(TIMEOUT_MS);
        req.setBody(JSON.serialize(body));
        Integer code;
        String responseBody;
        try {
            HttpResponse res = new Http().send(req);
            code = res.getStatusCode();
            responseBody = res.getBody();
        } catch (Exception e) {
            code = 503;
            responseBody = e.getMessage();
        }
        Map<String, Object> parsed = parse(responseBody);
        Boolean ok = code >= 200 && code < 300;
        Boolean async = ok && code == 202 && String.isNotBlank(callbackEvent);

        NF_Fulfillment_Event__c ev = new NF_Fulfillment_Event__c(
            Order__c = o?.Id, Account__c = o?.AccountId, Step_Id__c = stepId, Step_Name__c = stepName.left(120),
            System__c = sourceSystem, Event_Type__c = 'Callout', Status__c = !ok ? 'Failed' : async ? 'Pending' : 'Completed',
            Callback_Event__c = async ? callbackEvent : null,
            External_Ref__c = firstOf(parsed, new List<String>{ 'trackingNumber', 'billingAccountNumber', 'subscriptionId', 'circuitId', 'portId', 'requestId' }),
            Due_At__c = async ? DateTime.now().addMinutes(delay) : null, Customer_Visible__c = false,
            Message__c = (sourceSystem + ' · ' + (String.isBlank(stepName) ? path : stepName) + ' · HTTP ' + code
                + (async ? ' · callback ' + callbackEvent + ' in ~' + delay + ' min' : '')).left(255),
            Payload__c = ('REQUEST POST ' + path + '\n' + JSON.serializePretty(body) + '\n\nRESPONSE ' + code + '\n'
                + responseBody + '\n\nDRO INPUT requestGuid=' + requestGuid + ' inputRecordId=' + inputRecordId).left(32000));
        insert ev;
        if (ok && sourceSystem == 'Billing' && o != null && parsed.get('billingAccountNumber') != null) {
            update new Account(Id = o.AccountId, NF_Billing_Account_Number__c = String.valueOf(parsed.get('billingAccountNumber')));
        }
        if (async) {
            NF_FulfillmentSimulator.schedule(ev.Id, simulatedDelayOverride != null ? simulatedDelayOverride : delay);
        }

        industriesintegrationfwk.IntegrationCalloutResponse r = new industriesintegrationfwk.IntegrationCalloutResponse(ok);
        r.setResponseCode(async ? 202 : ok ? 200 : code);
        r.setReturnValue(new Map<String, Object>{ 'isSuccess' => ok, 'response' => parsed });
        if (!ok) r.setErrorMessage((sourceSystem + ' answered HTTP ' + code).left(255));
        return r;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    @TestVisible
    private static Order orderOf(String inputRecordId) {
        Id orderId;
        try {
            Id rid = Id.valueOf(inputRecordId);
            Schema.SObjectType t = rid.getSObjectType();
            if (t == Order.SObjectType) orderId = rid;
            else if (t == OrderItem.SObjectType) orderId = [SELECT OrderId FROM OrderItem WHERE Id = :rid].OrderId;
            else if (t == FulfillmentOrderLineItem.SObjectType) {
                orderId = [SELECT FulfillmentOrder.OrderId FROM FulfillmentOrderLineItem WHERE Id = :rid].FulfillmentOrder.OrderId;
            } else if (t == FulfillmentOrder.SObjectType) orderId = [SELECT OrderId FROM FulfillmentOrder WHERE Id = :rid].OrderId;
        } catch (Exception e) {
            return null;
        }
        if (orderId == null) return null;
        return [SELECT Id, OrderNumber, AccountId, Account.Name, Account.NF_Billing_Account_Number__c, ShippingStreet, ShippingCity,
                       ShippingState, ShippingPostalCode, (SELECT Product2.ProductCode, Product2.Name, Quantity, TotalPrice FROM OrderItems)
                FROM Order WHERE Id = :orderId];
    }

    /** The running Fulfillment Step: from the request GUID, the payload's StepId/CorrelationId or the step source. */
    @TestVisible
    private static String stepIdOf(String requestGuid, String payload, String inputRecordId, String stepName) {
        if (requestGuid != null && requestGuid.startsWith('13W') && (requestGuid.length() == 15 || requestGuid.length() == 18)) return requestGuid;
        Map<String, Object> p = parse(payload);
        if (p.get('StepId') instanceof String && ((String) p.get('StepId')).startsWith('13W')) return (String) p.get('StepId');
        if (p.get('CorrelationId') instanceof String) {
            String c = ((String) p.get('CorrelationId')).substringBetween('callout:', ':');
            if (c != null && c.startsWith('13W')) return c;
        }
        if (String.isBlank(inputRecordId)) return null;
        List<FulfillmentStep> steps = [
            SELECT Id FROM FulfillmentStep
            WHERE StepType = 'Callout' AND State IN ('InProgress', 'Ready', 'Running')
              AND Id IN (SELECT StepId FROM FulfillmentStepSource WHERE SourceIdentifier = :inputRecordId OR SourceLineItemId = :inputRecordId)
            ORDER BY CreatedDate DESC LIMIT 10
        ];
        if (steps.isEmpty()) return null;
        if (String.isNotBlank(stepName)) {
            for (FulfillmentStep s : [SELECT Id, Name FROM FulfillmentStep WHERE Id IN :steps]) if (s.Name == stepName) return s.Id;
        }
        return steps[0].Id;
    }

    private static Map<String, Object> requestBody(Order o, String stepId, String stepName) {
        List<Object> items = new List<Object>();
        if (o != null) {
            for (OrderItem oi : o.OrderItems) {
                items.add(new Map<String, Object>{ 'sku' => oi.Product2.ProductCode, 'name' => oi.Product2.Name, 'quantity' => oi.Quantity });
            }
        }
        return new Map<String, Object>{
            'orderNumber' => o?.OrderNumber,
            'customerName' => o?.Account.Name,
            'billingAccountNumber' => o?.Account.NF_Billing_Account_Number__c,
            'serviceAddress' => o == null ? null : String.join(new List<String>{ o.ShippingStreet, o.ShippingCity, o.ShippingState, o.ShippingPostalCode }, ', '),
            'items' => items,
            'step' => stepName,
            'correlationId' => stepId,
            'callbackUrl' => URL.getOrgDomainUrl().toExternalForm() + CALLBACK_PATH
        };
    }

    private static String text(Map<String, Object> attrs, String key, String fallback) {
        Object v = attrs.get(key);
        return v == null || String.isBlank(String.valueOf(v)) ? fallback : String.valueOf(v);
    }

    private static Map<String, Object> parse(String body) {
        try {
            Object o = String.isBlank(body) ? null : JSON.deserializeUntyped(body);
            return o instanceof Map<String, Object> ? (Map<String, Object>) o : new Map<String, Object>();
        } catch (Exception e) {
            return new Map<String, Object>();
        }
    }

    private static String firstOf(Map<String, Object> m, List<String> keys) {
        for (String k : keys) if (m.get(k) != null) return String.valueOf(m.get(k)).left(80);
        return null;
    }
}
