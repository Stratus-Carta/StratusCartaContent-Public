@IsTest
private class NF_PortalTest {

    private static final String PASSWORD = 'NovaFiber2026';

    @TestSetup
    static void setup() {
        Account mine = new Account(Name = 'Ada Lovelace', NF_Service_Status__c = 'Equipment Shipped', NF_Billing_Account_Number__c = 'BA-1',
            ShippingStreet = '415 Mission St', ShippingCity = 'San Francisco', ShippingState = 'CA', ShippingPostalCode = '94105');
        Account other = new Account(Name = 'Someone Else');
        insert new List<Account>{ mine, other };
        insert new Contact(AccountId = mine.Id, FirstName = 'Ada', LastName = 'Lovelace', Email = 'ada@example.com');
        Order o = new Order(AccountId = mine.Id, EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId(),
            NF_Channel__c = NF_JourneyModels.CHANNEL_SELF_SERVICE, NF_Fulfillment_Status__c = 'Equipment Shipped',
            Description = 'Preferred install date: 10/24/2026');
        Order notMine = new Order(AccountId = other.Id, EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId(),
            NF_Channel__c = NF_JourneyModels.CHANNEL_SELF_SERVICE);
        insert new List<Order>{ o, notMine };
        insert new List<NF_Fulfillment_Event__c>{
            new NF_Fulfillment_Event__c(Order__c = o.Id, Account__c = mine.Id, Event_Type__c = 'Milestone', Milestone__c = 'Submitted', Message__c = 'received', Customer_Visible__c = true),
            new NF_Fulfillment_Event__c(Order__c = o.Id, Account__c = mine.Id, Event_Type__c = 'Milestone', Milestone__c = 'Order Confirmed', Message__c = 'confirmed', Customer_Visible__c = true),
            new NF_Fulfillment_Event__c(Order__c = o.Id, Account__c = mine.Id, Event_Type__c = 'Callout', Message__c = 'internal', Customer_Visible__c = false)
        };
    }

    private static Account mine() {
        return [SELECT Id FROM Account WHERE Name = 'Ada Lovelace'];
    }

    @IsTest
    static void registerAndLogIn() {
        Id contactId = [SELECT Id FROM Contact LIMIT 1].Id;
        String username = NF_PortalService.register(mine().Id, contactId, ' Ada@Example.com ', PASSWORD);
        Assert.areEqual('ada@example.com', username);
        NF_Portal_User__c u = [SELECT Password_Hash__c, Salt__c, Iterations__c FROM NF_Portal_User__c];
        Assert.areNotEqual(PASSWORD, u.Password_Hash__c, 'only the hash is stored');
        Assert.areEqual(64, u.Password_Hash__c.length());
        Assert.areEqual(NF_PortalService.ITERATIONS, u.Iterations__c);

        NF_JourneyModels.Envelope env = NF_PortalController.login('ADA@example.com', PASSWORD, false);
        Assert.isNull(env.error, 'error: ' + env.error);
        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(env.dataJson);
        String token = (String) r.get('token');
        Assert.areEqual(64, token.length());
        Assert.areEqual(0, [SELECT COUNT() FROM NF_Portal_Session__c WHERE Token_Hash__c = :token], 'the token itself is never stored');

        Map<String, Object> d = (Map<String, Object>) r.get('dashboard');
        Assert.areEqual('Ada', d.get('firstName'));
        Assert.areEqual('Equipment Shipped', d.get('serviceStatus'));
        Assert.areEqual('BA-1', d.get('billingAccountNumber'));
        Assert.areEqual(true, d.get('inProgress'));
        List<Object> orders = (List<Object>) d.get('orders');
        Assert.areEqual(1, orders.size(), 'only the customer\'s own orders');
        Map<String, Object> o = (Map<String, Object>) orders[0];
        Assert.areEqual(2, ((List<Object>) o.get('timeline')).size(), 'only customer-visible events');
        List<Object> milestones = (List<Object>) o.get('milestones');
        Assert.areEqual(4, milestones.size(), 'an order without internet or TV has the short journey');
        Assert.areEqual('done', ((Map<String, Object>) milestones[0]).get('state'));
        Assert.areEqual('Preferred install date: 10/24/2026', o.get('installDateNote'));

        NF_JourneyModels.Envelope again = NF_PortalController.getDashboard(token, false);
        Assert.isNull(again.error, 'error: ' + again.error);
        Assert.isNull(NF_PortalController.logout(token, false).error);
        Assert.isNotNull(NF_PortalController.getDashboard(token, false).error, 'logged out');
        Assert.isNotNull(NF_PortalController.getDashboard('short', false).error);

        update new NF_Portal_Session__c(Id = [SELECT Id FROM NF_Portal_Session__c LIMIT 1].Id, Expires_At__c = DateTime.now().addMinutes(-1));
        NF_JourneyCleanup.run();
        Assert.areEqual(0, [SELECT COUNT() FROM NF_Portal_Session__c], 'the cleanup removes ended sessions');
    }

    @IsTest
    static void wrongPasswordsLockTheLogin() {
        NF_PortalService.register(mine().Id, null, 'ada@example.com', PASSWORD);
        for (Integer i = 1; i < NF_PortalService.MAX_FAILURES; i++) {
            Assert.areEqual('That email and password don\'t match our records.', NF_PortalController.login('ada@example.com', 'wrong-pass-1', false).error);
        }
        Assert.isTrue(NF_PortalController.login('ada@example.com', 'wrong-pass-1', false).error.contains('Too many attempts'));
        Assert.isTrue(NF_PortalController.login('ada@example.com', PASSWORD, false).error.contains('Too many attempts'), 'locked even with the right password');
        Assert.isNotNull(NF_PortalController.login('nobody@example.com', PASSWORD, false).error);
        Assert.isNotNull(NF_PortalController.login('ada@example.com', '', false).error);
    }

    @IsTest
    static void passwordRulesAndExistingLogins() {
        for (String weak : new List<String>{ null, 'short1', 'longbutnodigits', '1234567890123' }) {
            try {
                NF_PortalService.checkPasswordRules(weak);
                Assert.fail('weak password accepted: ' + weak);
            } catch (NF_JourneyModels.JourneyException e) {
                Assert.isTrue(e.getMessage().contains('10 characters'), e.getMessage());
            }
        }
        NF_PortalService.register(mine().Id, null, 'ada@example.com', PASSWORD);
        Assert.isTrue(NF_PortalService.exists('ADA@example.com'));
        // ordering again with the same email keeps the existing password
        NF_PortalService.register(mine().Id, [SELECT Id FROM Contact LIMIT 1].Id, 'ada@example.com', 'Different2026x');
        Assert.isNull(NF_PortalController.login('ada@example.com', PASSWORD, false).error);
        NF_PortalService.linkContact('ada@example.com', mine().Id, null);
        try {
            NF_PortalService.register(mine().Id, null, '  ', PASSWORD);
            Assert.fail('no email');
        } catch (NF_JourneyModels.JourneyException e) {
            Assert.isTrue(e.getMessage().contains('email'));
        }
    }

    @IsTest
    static void internetOrdersShowTheFullJourney() {
        Account a = mine();
        Order o = [SELECT Id FROM Order WHERE AccountId = :a.Id];
        NF_FulfillmentStatus.apply(o.Id, 'Needs Attention', null, null, null);   // not a milestone: ignored
        update new Order(Id = o.Id, NF_Fulfillment_Status__c = NF_FulfillmentStatus.NEEDS_ATTENTION);
        NF_PortalController.Dashboard d = NF_PortalController.dashboard('ada@example.com', a.Id, null);
        Assert.areEqual(1, d.orders.size());
        Assert.isTrue(d.orders[0].needsAttention);
        Assert.areEqual('attention', d.orders[0].milestones[1].state, 'the last reached milestone is flagged');
        NF_PortalController.Dashboard empty = NF_PortalController.dashboard('x@example.com', null, null);
        Assert.areEqual(0, empty.orders.size());
    }
}
