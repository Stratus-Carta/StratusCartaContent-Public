// Multi-site pricing check: one quote, two Location recipients (NY + TX) each with its QuoteLineGroup, the same products on each,
// placed with pricingPref System. The LocationBasedPrice step should price each line from
// LocationBasedDecisionTable using its own recipient's ServiceState (filled by ApexDmlAttributePreHook).
// Creates a test quote "NovaFiber Multi-site Test …"; delete it afterwards.
String place = '/connect/rev/sales-transaction/actions/place';
Id pricebookId = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
Id accountId = [SELECT QuoteAccountId FROM Quote WHERE QuoteNumber = '00000332' LIMIT 1].QuoteAccountId;
String today = String.valueOf(Date.today());

Map<String, String> cities = new Map<String, String>{ 'NY' => 'New York|350 5th Ave|10001', 'TX' => 'Austin|1100 Congress Ave|73301' };
List<Object> header = new List<Object>{ new Map<String, Object>{ 'referenceId' => 'refQuote', 'record' => new Map<String, Object>{
    'attributes' => new Map<String, Object>{ 'type' => 'Quote', 'method' => 'POST' },
    'Name' => 'NovaFiber Multi-site Test ' + DateTime.now().format('HHmmss'),
    'Pricebook2Id' => pricebookId, 'QuoteAccountId' => accountId, 'StartDate' => today } } };
for (String st : cities.keySet()) {
    List<String> c = cities.get(st).split('\\|');
    header.add(new Map<String, Object>{ 'referenceId' => 'refSite' + st, 'record' => new Map<String, Object>{
        'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineItemRecipient', 'method' => 'POST' },
        'QuoteId' => '@{refQuote.id}', 'Name' => 'Site ' + st + ' - ' + c[1], 'RecipientType' => 'Location',
        'ServiceStreet' => c[1], 'ServiceCity' => c[0], 'ServiceState' => st, 'ServicePostalCode' => c[2],
        'ServiceCountry' => 'US', 'ServiceAddrValidationResult' => 'Success' } });
    header.add(new Map<String, Object>{ 'referenceId' => 'refGroup' + st, 'record' => new Map<String, Object>{
        'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineGroup', 'method' => 'POST' },
        'QuoteId' => '@{refQuote.id}', 'Name' => 'Site ' + st + ' - ' + c[1] } });
}
Map<String, Object> placed = NF_RevCloudApi.post(place, new Map<String, Object>{
    'pricingPref' => 'Skip', 'configurationPref' => new Map<String, Object>{ 'configurationMethod' => 'Skip' },
    'graph' => new Map<String, Object>{ 'graphId' => 'msHeader', 'records' => header } }, 'multi-site header');
Id quoteId = (Id) String.valueOf(placed.get('salesTransactionId'));
System.debug('QUOTE ' + quoteId + ' ' + JSON.serialize(placed).left(300));

Map<String, Id> groupByState = new Map<String, Id>();
for (QuoteLineGroup g : [SELECT Id, Name FROM QuoteLineGroup WHERE QuoteId = :quoteId]) groupByState.put(g.Name.substringBetween('Site ', ' -'), g.Id);
System.debug('GROUPS ' + groupByState);
Map<String, Id> siteByState = new Map<String, Id>();
for (QuoteLineItemRecipient r : [SELECT Id, ServiceState FROM QuoteLineItemRecipient WHERE QuoteId = :quoteId]) siteByState.put(r.ServiceState, r.Id);

List<Object> lines = new List<Object>{ new Map<String, Object>{ 'referenceId' => quoteId, 'record' => new Map<String, Object>{
    'attributes' => new Map<String, Object>{ 'type' => 'Quote', 'method' => 'PATCH', 'id' => quoteId }, 'StartDate' => today } } };
Integer n = 0;
for (PricebookEntry pbe : [SELECT Id, Product2Id, Product2.ProductCode FROM PricebookEntry WHERE Pricebook2Id = :pricebookId
                           AND Product2.ProductCode IN ('NFR-INT-1G', 'NFR-MOB-ESS') AND IsActive = true]) {
    for (String st : siteByState.keySet()) {
        n++;
        lines.add(new Map<String, Object>{ 'referenceId' => 'refL' + n, 'record' => new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineItem', 'method' => 'POST' },
            'QuoteId' => quoteId, 'Product2Id' => pbe.Product2Id, 'PricebookEntryId' => pbe.Id, 'Quantity' => 1,
            'StartDate' => today, 'PeriodBoundary' => 'Anniversary', 'BillingFrequency' => 'Monthly',
            'QuoteLineItemRecipientId' => siteByState.get(st), 'QuoteLineGroupId' => groupByState.get(st) } });
    }
}
Map<String, Object> placedLines = NF_RevCloudApi.post(place, new Map<String, Object>{
    'pricingPref' => 'System',
    'configurationPref' => new Map<String, Object>{ 'configurationMethod' => 'System', 'configurationOptions' => new Map<String, Object>{
        'validateProductCatalog' => true, 'executeConfigurationRules' => true, 'addDefaultConfiguration' => false } },
    'graph' => new Map<String, Object>{ 'graphId' => 'msLines', 'records' => lines } }, 'multi-site lines');
System.debug('LINES ' + JSON.serialize(placedLines).left(400));

for (QuoteLineItem li : [SELECT Product2.ProductCode, QuoteLineItemRecipient.ServiceState, QuoteLineGroup.Name, ListPrice, UnitPrice, NetUnitPrice, LocationState__c
                         FROM QuoteLineItem WHERE QuoteId = :quoteId ORDER BY Product2.ProductCode, QuoteLineItemRecipient.ServiceState]) {
    System.debug('LINE ' + li.Product2.ProductCode + ' ' + li.QuoteLineItemRecipient.ServiceState + ' list=' + li.ListPrice
        + ' unit=' + li.UnitPrice + ' net=' + li.NetUnitPrice + ' group=' + li.QuoteLineGroup.Name);
}
