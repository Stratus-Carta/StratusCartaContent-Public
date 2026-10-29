// NovaFiber state-based prices for multi-site quoting: one ItemLocationPrice__c row per NFR (residential) and
// NFB (business) product and state (zero-priced products too, so the location lookup never comes back empty).
// LocationBasedDecisionTable reads them for the Location Based Price step of the quote pricing procedure, both on
// quotes and while browsing (configurator sessions on the NovaFiber Location Pricing Workspace quote).
// States are 2-letter codes, as written to QuoteLineItemRecipient.ServiceState.
// Re-runnable: replaces the NFR and NFB rows. Then refresh the table:
//   sf api request rest -o RCPOC -X POST /services/data/v66.0/actions/standard/refreshDecisionTable
//     --body '{"inputs":[{"decisionTableApiName":"LocationBasedDecisionTable"}]}'
Map<String, Decimal> stateFactor = new Map<String, Decimal>{
    'NY' => 1.10, 'CA' => 1.12, 'IL' => 1.03, 'GA' => 0.96, 'TX' => 0.94, 'AK' => 1.18
};

delete [SELECT Id FROM ItemLocationPrice__c WHERE Product__r.ProductCode LIKE 'NFR-%' OR Product__r.ProductCode LIKE 'NFB-%'];

List<ItemLocationPrice__c> rows = new List<ItemLocationPrice__c>();
for (PricebookEntry pbe : [SELECT Product2Id, Pricebook2Id, ProductSellingModelId, UnitPrice FROM PricebookEntry
                           WHERE (Product2.ProductCode LIKE 'NFR-%' OR Product2.ProductCode LIKE 'NFB-%') AND IsActive = true
                           AND Pricebook2.IsStandard = true]) {
    for (String state : stateFactor.keySet()) {
        Decimal p = pbe.UnitPrice * stateFactor.get(state);
        // Shelf-style prices: $20+ ends in .99, smaller amounts keep cents.
        Decimal price = p >= 20 ? p.setScale(0, RoundingMode.HALF_UP) - 0.01 : p.setScale(2, RoundingMode.HALF_UP);
        rows.add(new ItemLocationPrice__c(Product__c = pbe.Product2Id, Price_Book__c = pbe.Pricebook2Id,
            Product_Selling_Model__c = pbe.ProductSellingModelId, LocationState__c = state, Unit_Price__c = price));
    }
}
insert rows;
System.debug('NovaFiber location prices: ' + rows.size());
