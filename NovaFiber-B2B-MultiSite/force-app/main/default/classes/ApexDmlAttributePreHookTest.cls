@IsTest
private class ApexDmlAttributePreHookTest {

    /** Stands in for Context Service: returns the given items and records the attribute updates. */
    private class FakeContext implements ApexDmlAttributePreHook.ContextGateway {
        List<Object> items;
        Boolean failUpdate = false;
        List<Map<String, Object>> updates;
        FakeContext(List<Object> items) { this.items = items; }
        public List<Object> queryItems(String contextId) { return items; }
        public void updateAttributes(String contextId, List<Map<String, Object>> updates) {
            if (failUpdate) throw new IllegalArgumentException('context write failed');
            this.updates = updates;
        }
    }

    private static Map<String, Object> item(String itemId, String recipient, String state, String cfgStatus, String actionCode) {
        Map<String, Object> tags = new Map<String, Object>();
        if (recipient != null) tags.put('ItemSalesTransactionRecipient', new Map<String, Object>{ 'tagValue' => recipient });
        if (state != null) tags.put('ItemLocationState__c', new Map<String, Object>{ 'tagValue' => state });
        return new Map<String, Object>{
            'dataPath' => new List<Object>{ 'ctx-1', 'quote-1', itemId },
            'cfgStatus' => cfgStatus,
            'actionCode' => actionCode,
            'tagValue' => tags
        };
    }

    private static Id serviceLocation(String state) {
        Account a = new Account(Name = 'Pre-hook Test');
        insert a;
        Quote q = new Quote(Name = 'Pre-hook Test', QuoteAccountId = a.Id, Pricebook2Id = Test.getStandardPricebookId());
        insert q;
        QuoteLineItemRecipient r = new QuoteLineItemRecipient(QuoteId = q.Id, Name = 'Site', RecipientType = 'Location',
            ServiceState = state);
        insert r;
        return r.Id;
    }

    @IsTest
    static void setsTheStateOfEachLinesServiceLocation() {
        Id ny = serviceLocation('NY');
        String orderRecipient = OrderItemRecipient.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';
        FakeContext fake = new FakeContext(new List<Object>{
            item('line-new', ny, null, 'New', null),                 // gets NY
            item('line-changed', ny, 'TX', 'Changed', null),         // TX → NY
            item('line-same', ny, 'NY', null, null),                 // already NY: no write
            item('line-deleted', ny, null, 'New', 'Delete'),         // being deleted
            item('line-unchanged', ny, null, 'Unchanged', null),     // configurator says unchanged
            item('line-placeholder', '@{refSite.id}', null, 'New', null),   // not a record id
            item('line-order', orderRecipient, null, 'New', null),   // order recipient without a state
            new Map<String, Object>{ 'dataPath' => new List<Object>{ 'ctx-1' } }   // not a line
        });
        ApexDmlAttributePreHook.gateway = fake;
        ApexDmlAttributePreHook.DEBUG = true;

        Test.startTest();
        RevSignaling.TransactionResponse res = new ApexDmlAttributePreHook().execute(null);
        Test.stopTest();

        Assert.areEqual(RevSignaling.TransactionStatus.SUCCESS, res.status);
        Assert.areEqual(2, fake.updates.size(), 'only the new and the changed line');
        Map<String, Object> first = fake.updates[0];
        Assert.areEqual(new List<Object>{ 'quote-1', 'line-new' },
            ((Map<String, Object>) first.get('nodePath')).get('dataPath'), 'path without the context id');
        Map<String, Object> attr = (Map<String, Object>) ((List<Object>) first.get('attributes'))[0];
        Assert.areEqual('ItemLocationState__c', attr.get('attributeName'));
        Assert.areEqual('NY', attr.get('attributeValue'));
    }

    @IsTest
    static void aFailedWriteDoesNotBlockPricing() {
        Id ca = serviceLocation('CA');
        FakeContext fake = new FakeContext(new List<Object>{ item('line-1', ca, null, 'New', null) });
        fake.failUpdate = true;
        ApexDmlAttributePreHook.gateway = fake;

        RevSignaling.TransactionResponse res = new ApexDmlAttributePreHook().execute(null);
        Assert.areEqual(RevSignaling.TransactionStatus.SUCCESS, res.status);
        Assert.isNull(fake.updates);
    }

    @IsTest
    static void nothingToDoWithoutLines() {
        FakeContext fake = new FakeContext(null);
        ApexDmlAttributePreHook.gateway = fake;
        RevSignaling.TransactionResponse res = new ApexDmlAttributePreHook().execute(null);
        Assert.areEqual(RevSignaling.TransactionStatus.SUCCESS, res.status);
        Assert.isNull(fake.updates, 'no context write');
        Assert.isNull(ApexDmlAttributePreHook.toId(' '));
    }
}
