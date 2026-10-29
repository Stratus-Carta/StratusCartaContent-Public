// Creates the shared configurator workspace (idempotent). Carts are configured in Revenue Cloud configurator
// sessions on this quote; the journey never saves to it, so it stays empty and serves every shopper at once.
String name = NF_QuoteService.WORKSPACE_NAME;
List<Quote> existing = [SELECT Id, QuoteNumber FROM Quote WHERE Name = :name AND NF_Channel__c = null LIMIT 1];
if (!existing.isEmpty()) {
    System.debug('NF workspace exists: Quote ' + existing[0].QuoteNumber + ' ' + existing[0].Id);
    return;
}
Account a = new Account(Name = name, Description = 'Holds the configurator workspace quote for the NovaFiber journey. Do not delete or add quote lines.');
Database.insert(a, NF_QuoteService.allowDuplicates());
Id pb = [SELECT Id FROM Pricebook2 WHERE IsStandard = true AND IsActive = true LIMIT 1].Id;
Quote q = new Quote(Name = name, QuoteAccountId = a.Id, Pricebook2Id = pb,
    Description = 'Shared Revenue Cloud configurator workspace for NovaFiber carts. Never saved to; do not edit.');
insert q;
System.debug('NF workspace created: Quote ' + [SELECT QuoteNumber FROM Quote WHERE Id = :q.Id].QuoteNumber + ' ' + q.Id);
