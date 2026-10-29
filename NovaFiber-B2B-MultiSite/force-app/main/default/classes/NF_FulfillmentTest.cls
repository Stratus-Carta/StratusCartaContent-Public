@IsTest
private class NF_FulfillmentTest {

    /** Mock Provisioning / Logistics / Billing systems behind NF_FulfillmentSystems. */
    private class SystemsMock implements HttpCalloutMock {
        Integer code;
        String body;
        String lastBody;
        SystemsMock(Integer code, String body) { this.code = code; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            if (req.getEndpoint() == 'callout:NF_RevenueCloud' + NF_DroCalloutProvider.CALLBACK_PATH) {
                // the simulated external system calling this org back
                r.setStatusCode(200);
                r.setBody(JSON.serialize(NF_FulfillmentCallbackApi.process(
                    (Map<String, Object>) JSON.deserializeUntyped(req.getBody()))));
                return r;
            }
            System.assert(req.getEndpoint().startsWith('callout:NF_FulfillmentSystems/'), req.getEndpoint());
            lastBody = req.getBody();
            r.setStatusCode(code);
            r.setBody(body);
            return r;
        }
    }

    /** Revenue Cloud REST (order activation, submitOrder) through NF_RevCloudApi. */
    private class FakeRevenueCloud implements NF_RevCloudApi.Responder {
        Boolean failSubmit = false;
        List<String> calls = new List<String>();
        public String respond(String method, String path, String requestBody) {
            calls.add(method + ' ' + path);
            if (path == '/actions/standard/submitOrder') {
                return failSubmit
                    ? '[{"actionName":"submitOrder","isSuccess":false,"errors":[{"message":"DRO is busy"}],"outputValues":{}}]'
                    : '[{"actionName":"submitOrder","isSuccess":true,"outputValues":{"submitStatus":"SUBMITTED","requestId":"req-1"}}]';
            }
            return '';
        }
    }

    @TestSetup
    static void setup() {
        Account a = new Account(Name = 'NovaFiber Prospect - 94105 - test', BillingPostalCode = '94105');
        insert a;
        insert new Order(AccountId = a.Id, EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId(),
            ShippingStreet = '415 Mission St', ShippingCity = 'San Francisco', ShippingState = 'CA', ShippingPostalCode = '94105');
    }

    private static Order theOrder() {
        return [SELECT Id, AccountId, NF_Fulfillment_Status__c, Account.NF_Service_Status__c FROM Order LIMIT 1];
    }

    /** A running DRO plan with one waiting step of the given type (DRO itself creates these in the org). */
    private static FulfillmentStep runningStep(Id orderId, String name, String stepType) {
        FulfillmentPlan plan = new FulfillmentPlan(SourceIdentifier = orderId, State = 'InProgress');
        insert plan;
        FulfillmentStep s = new FulfillmentStep(Name = name, FulfillmentPlanId = plan.Id, StepType = stepType, State = 'InProgress');
        insert s;
        return s;
    }

    @IsTest
    static void milestonesOnlyMoveForward() {
        Order o = theOrder();
        Test.startTest();
        Assert.isTrue(NF_FulfillmentStatus.apply(o.Id, 'Network Reserved', 'Orchestrator', null, null));
        Assert.isFalse(NF_FulfillmentStatus.apply(o.Id, 'Order Confirmed', 'Orchestrator', null, null), 'a late milestone never goes back');
        Assert.isFalse(NF_FulfillmentStatus.apply(o.Id, 'Nonsense', 'Orchestrator', null, null));
        Test.stopTest();
        o = theOrder();
        Assert.areEqual('Network Reserved', o.NF_Fulfillment_Status__c);
        Assert.areEqual('Network Reserved', o.Account.NF_Service_Status__c, 'the customer account shows the milestone');
        Assert.areEqual(2, [SELECT COUNT() FROM NF_Fulfillment_Event__c WHERE Event_Type__c = 'Milestone' AND Customer_Visible__c = true]);
        Assert.areEqual('Your NovaFiber service is live.', NF_FulfillmentStatus.customerText('Service Active'));
    }

    @IsTest
    static void autoTaskFlowsSetMilestonesAndValidate() {
        Order o = theOrder();
        NF_FulfillmentStatus.Request r = new NF_FulfillmentStatus.Request();
        r.orderId = o.Id;
        r.milestone = 'Order Confirmed';
        NF_FulfillmentStatus.setMilestone(new List<NF_FulfillmentStatus.Request>{ r });
        Assert.areEqual('Order Confirmed', theOrder().NF_Fulfillment_Status__c);

        NF_FulfillmentStatus.Request v = new NF_FulfillmentStatus.Request();
        v.orderId = o.Id;   // no milestone: validate. The draft test order has no items, so it fails.
        try {
            NF_FulfillmentStatus.setMilestone(new List<NF_FulfillmentStatus.Request>{ v });
            Assert.fail('validation should fail');
        } catch (NF_JourneyModels.JourneyException e) {
            Assert.isTrue(e.getMessage().contains('not activated'), e.getMessage());
        }
    }

    @IsTest
    static void ordersAreActivatedAndSubmittedToDro() {
        Order o = theOrder();
        FakeRevenueCloud rc = new FakeRevenueCloud();
        NF_RevCloudApi.responder = rc;
        Test.startTest();
        NF_DroService.Submission s = NF_DroService.submit(o.Id, null);
        NF_DroService.recordSubmission(o.Id, s);
        Test.stopTest();
        Assert.isTrue(s.submitted, 'error: ' + s.error);
        Assert.areEqual('PATCH /sobjects/Order/' + o.Id, rc.calls[0], 'activate first');
        Assert.areEqual('POST /actions/standard/submitOrder', rc.calls[1]);
        Order after = [SELECT NF_Fulfillment_Status__c, NF_Submitted_To_DRO__c, NF_DRO_Request_Id__c FROM Order WHERE Id = :o.Id];
        Assert.areEqual('Submitted', after.NF_Fulfillment_Status__c);
        Assert.areEqual('req-1', after.NF_DRO_Request_Id__c);
        Assert.isNotNull(after.NF_Submitted_To_DRO__c);
    }

    @IsTest
    static void droFailuresAreFlaggedNotLost() {
        Order o = theOrder();
        FakeRevenueCloud rc = new FakeRevenueCloud();
        rc.failSubmit = true;
        NF_RevCloudApi.responder = rc;
        Test.startTest();
        NF_DroService.Submission s = NF_DroService.submit(o.Id, null);
        NF_DroService.recordSubmission(o.Id, s);
        Test.stopTest();
        Assert.isFalse(s.submitted);
        Assert.areEqual(NF_FulfillmentStatus.NEEDS_ATTENTION, theOrder().NF_Fulfillment_Status__c);
        Assert.areEqual(1, [SELECT COUNT() FROM NF_Fulfillment_Event__c WHERE Status__c = 'Failed']);
    }

    @IsTest
    static void asyncCalloutWaitsForTheCallback() {
        Order o = theOrder();
        FulfillmentStep step = runningStep(o.Id, 'Reserve network port', 'Callout');
        SystemsMock mock = new SystemsMock(202, '{"requestId":"PRV-RSV-1","status":"ACCEPTED","portId":"OLT-1"}');
        Test.setMock(HttpCalloutMock.class, mock);
        NF_DroCalloutProvider provider = new NF_DroCalloutProvider();
        Assert.areEqual(6, provider.getProviderAttributes().size());

        Test.startTest();
        industriesintegrationfwk.IntegrationCalloutResponse r = provider.executeCallout(step.Id, o.Id, '', new Map<String, Object>{
            'NF_System' => 'Provisioning', 'NF_Path' => '/provisioning/v1/reservations', 'NF_Step_Name' => 'Reserve network port',
            'NF_Callback_Event' => 'RESERVED', 'NF_Callback_Delay_Minutes' => '1' });
        Assert.isTrue(mock.lastBody.contains('"correlationId":"' + step.Id + '"'), mock.lastBody);
        Test.stopTest();   // runs the simulated callback

        NF_Fulfillment_Event__c callout = [SELECT Status__c, External_Ref__c, Callback_Event__c FROM NF_Fulfillment_Event__c WHERE Event_Type__c = 'Callout'];
        Assert.areEqual('Completed', callout.Status__c, 'the callback closed the pending event');
        Assert.areEqual('OLT-1', callout.External_Ref__c, 'the port id is the useful reference');
        Assert.areEqual('Completed', [SELECT State FROM FulfillmentStep WHERE Id = :step.Id].State, 'the callback completed the DRO step');
        Assert.areEqual(1, [SELECT COUNT() FROM NF_Fulfillment_Event__c WHERE Event_Type__c = 'Callback' AND Callback_Event__c = 'RESERVED']);
    }

    @IsTest
    static void syncBillingCalloutStoresTheBillingAccount() {
        Order o = theOrder();
        FulfillmentStep step = runningStep(o.Id, 'Create billing account', 'Callout');
        Test.setMock(HttpCalloutMock.class, new SystemsMock(201, '{"status":"CREATED","billingAccountNumber":"BA-1"}'));
        Test.startTest();
        new NF_DroCalloutProvider().executeCallout(null, o.Id, '{"CorrelationId":"callout:' + step.Id + ':"}', new Map<String, Object>{
            'NF_System' => 'Billing', 'NF_Path' => '/billing/v1/accounts' });
        Test.stopTest();
        Assert.areEqual('BA-1', [SELECT NF_Billing_Account_Number__c FROM Account WHERE Id = :o.AccountId].NF_Billing_Account_Number__c);
        NF_Fulfillment_Event__c ev = [SELECT Status__c, Step_Id__c FROM NF_Fulfillment_Event__c];
        Assert.areEqual('Completed', ev.Status__c, 'synchronous: no callback owed');
        Assert.areEqual(step.Id, ev.Step_Id__c, 'step id from the payload correlation id');
    }

    @IsTest
    static void failedCalloutsAreReported() {
        Order o = theOrder();
        Test.setMock(HttpCalloutMock.class, new SystemsMock(500, 'down'));
        Test.startTest();
        industriesintegrationfwk.IntegrationCalloutResponse r = new NF_DroCalloutProvider().executeCallout(null, o.Id, null,
            new Map<String, Object>{ 'NF_System' => 'Logistics', 'NF_Path' => '/logistics/v1/shipments', 'NF_Callback_Event' => 'SHIPPED' });
        Test.stopTest();
        Assert.areEqual('Failed', [SELECT Status__c FROM NF_Fulfillment_Event__c].Status__c);
        Assert.isNull(NF_DroCalloutProvider.orderOf('not-an-id'));
    }

    @IsTest
    static void shippingSchedulesDeliveryWhichResumesThePause() {
        Order o = theOrder();
        FulfillmentStep ship = runningStep(o.Id, 'Ship equipment', 'Callout');
        FulfillmentStep pause = new FulfillmentStep(Name = NF_FulfillmentCallbackApi.DELIVERY_PAUSE_STEP, FulfillmentPlanId =
            [SELECT FulfillmentPlanId FROM FulfillmentStep WHERE Id = :ship.Id].FulfillmentPlanId, StepType = 'Pause', State = 'InProgress');
        insert pause;
        Test.setMock(HttpCalloutMock.class, new SystemsMock(200, '{}'));
        Test.startTest();
        Map<String, Object> out = NF_FulfillmentCallbackApi.process(new Map<String, Object>{
            'stepId' => ship.Id, 'system' => 'Logistics', 'event' => 'SHIPPED', 'externalRef' => '1Z999', 'status' => 'SUCCESS' });
        Assert.areEqual('COMPLETED', out.get('outcome'));
        Test.stopTest();   // the delivery callback runs
        Assert.areEqual('Completed', [SELECT State FROM FulfillmentStep WHERE Id = :pause.Id].State, 'delivery resumed the pause step');
        Assert.areEqual('Equipment Delivered', theOrder().NF_Fulfillment_Status__c);
        Assert.areEqual('ALREADY_DONE', NF_FulfillmentCallbackApi.process(new Map<String, Object>{ 'stepId' => ship.Id, 'event' => 'SHIPPED' }).get('outcome'));
        Assert.areEqual('NOT_FOUND', NF_FulfillmentCallbackApi.process(new Map<String, Object>{ 'stepId' => null }).get('outcome'));
    }

    @IsTest
    static void callbacksWaitForStepsThatHaveNotStarted() {
        Order o = theOrder();
        FulfillmentStep s = runningStep(o.Id, 'Activate service', 'Callout');
        update new FulfillmentStep(Id = s.Id, State = 'Pending');
        Assert.areEqual('RETRY', NF_FulfillmentCallbackApi.process(new Map<String, Object>{ 'stepId' => s.Id, 'event' => 'ACTIVATED' }).get('outcome'));

        update new FulfillmentStep(Id = s.Id, State = 'InProgress');
        // a callback that never finds its step ready is given up after the retries
        NF_Fulfillment_Event__c pending = new NF_Fulfillment_Event__c(Order__c = o.Id, Step_Id__c = s.Id, System__c = 'Provisioning',
            Event_Type__c = 'Callout', Status__c = 'Pending', Callback_Event__c = 'ACTIVATED');
        insert pending;
        update new FulfillmentStep(Id = s.Id, State = 'Pending');
        Test.setMock(HttpCalloutMock.class, new SystemsMock(200, '{}'));
        Test.startTest();
        System.enqueueJob(new NF_FulfillmentSimulator(pending.Id, NF_FulfillmentSimulator.MAX_ATTEMPTS));
        Test.stopTest();
        Assert.areEqual('Failed', [SELECT Status__c FROM NF_Fulfillment_Event__c WHERE Id = :pending.Id].Status__c);
        update new FulfillmentStep(Id = s.Id, State = 'InProgress');

        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'stepId' => s.Id, 'system' => 'Billing', 'event' => 'BILLING_STARTED' }));
        RestContext.request = req;
        RestContext.response = new RestResponse();
        NF_FulfillmentCallbackApi.receive();
        Assert.areEqual(200, RestContext.response.statusCode);
        Assert.areEqual('Billing Started', theOrder().NF_Fulfillment_Status__c);

        RestContext.request.requestBody = Blob.valueOf('not json');
        NF_FulfillmentCallbackApi.receive();
        Assert.areEqual(400, RestContext.response.statusCode);
    }
}
