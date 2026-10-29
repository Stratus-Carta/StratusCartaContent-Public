// Browse-time location pricing check: a configurator session on the "NovaFiber Location Pricing Workspace"
// quote prices products against a per-state Location recipient, so LocationBasedPrice (quote pricing procedure)
// reads ItemLocationState__c via ApexDmlAttributePreHook. Nothing is saved: the session is discarded.
// First run creates the workspace quote + NY/TX recipients through Place Sales Transaction.
String place = '/connect/rev/sales-transaction/actions/place';
String configure = '/connect/cpq/configurator/actions/configure';
String wsName = 'NovaFiber Location Pricing Workspace';
Id pricebookId = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
String today = String.valueOf(Date.today());

List<Quote> ws = [SELECT Id, QuoteAccountId FROM Quote WHERE Name = :wsName LIMIT 1];
Id wsId;
if (ws.isEmpty()) {
    Id accountId = [SELECT QuoteAccountId FROM Quote WHERE Name = 'NovaFiber Configurator Workspace' LIMIT 1].QuoteAccountId;
    List<Object> recs = new List<Object>{ new Map<String, Object>{ 'referenceId' => 'refQuote', 'record' => new Map<String, Object>{
        'attributes' => new Map<String, Object>{ 'type' => 'Quote', 'method' => 'POST' },
        'Name' => wsName, 'Pricebook2Id' => pricebookId, 'QuoteAccountId' => accountId, 'StartDate' => today } } };
    for (String st : new List<String>{ 'NY', 'TX' }) {
        recs.add(new Map<String, Object>{ 'referenceId' => 'ref' + st, 'record' => new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineItemRecipient', 'method' => 'POST' },
            'QuoteId' => '@{refQuote.id}', 'Name' => 'Pricing location ' + st, 'RecipientType' => 'Location',
            'ServiceState' => st, 'ServiceCountry' => 'US' } });
    }
    Map<String, Object> placed = NF_RevCloudApi.post(place, new Map<String, Object>{
        'pricingPref' => 'Skip', 'configurationPref' => new Map<String, Object>{ 'configurationMethod' => 'Skip' },
        'graph' => new Map<String, Object>{ 'graphId' => 'locWs', 'records' => recs } }, 'location pricing workspace');
    wsId = (Id) String.valueOf(placed.get('salesTransactionId'));
} else {
    wsId = ws[0].Id;
}
Map<String, Id> recipientByState = new Map<String, Id>();
for (QuoteLineItemRecipient r : [SELECT Id, ServiceState FROM QuoteLineItemRecipient WHERE QuoteId = :wsId]) recipientByState.put(r.ServiceState, r.Id);
System.debug('WS ' + wsId + ' ' + recipientByState);

List<PricebookEntry> pbes = [SELECT Id, Product2Id, Product2.ProductCode, ProductSellingModelId FROM PricebookEntry
                             WHERE Pricebook2Id = :pricebookId AND Product2.ProductCode IN ('NFR-INT-1G', 'NFR-MOB-ESS') AND IsActive = true];
for (String st : new List<String>{ 'TX', 'NY' }) {
    List<Object> added = new List<Object>();
    Integer n = 0;
    for (PricebookEntry pbe : pbes) {
        n++;
        String id = 'loc' + st + n;
        added.add(new Map<String, Object>{ 'path' => new List<Object>{ wsId, id }, 'addedObject' => new Map<String, Object>{
            'businessObjectType' => 'QuoteLineItem', 'id' => id, 'SalesTransactionItemSource' => id,
            'SalesTransactionItemParent' => wsId, 'Product' => pbe.Product2Id, 'PricebookEntry' => pbe.Id,
            'ProductSellingModel' => pbe.ProductSellingModelId, 'Quantity' => 1, 'StartDate' => today,
            'PeriodBoundary' => 'Anniversary', 'BillingFrequency' => 'Monthly',
            'SalesTransactionRecipient' => recipientByState.get(st) } });
    }
    Map<String, Object> res = NF_RevCloudApi.post(configure, new Map<String, Object>{
        'transactionId' => wsId, 'contextResponseType' => 'Full', 'addedNodes' => added,
        'configuratorOptions' => new Map<String, Object>{ 'executePricing' => true, 'executeConfigurationRules' => false,
            'addDefaultConfiguration' => false, 'validateProductCatalog' => false } }, 'session location pricing ' + st);
    System.debug('SUCCESS ' + st + ' ' + res.get('success') + ' ' + JSON.serialize(res.get('errors')).left(300));
    Map<String, Object> tc = (Map<String, Object>) res.get('transactionContext');
    for (Object o : (List<Object>) tc.get('SalesTransaction')) {
        for (Object li : (List<Object>) ((Map<String, Object>) o).get('SalesTransactionItem')) {
            Map<String, Object> m = (Map<String, Object>) li;
            System.debug('PRICE ' + st + ' ' + m.get('ProductCode') + ' list=' + m.get('ListPrice') + ' unit=' + m.get('UnitPrice')
                + ' net=' + m.get('NetUnitPrice') + ' state=' + m.get('ItemLocationState__c') + ' recip=' + m.get('SalesTransactionRecipient'));
        }
    }
}
