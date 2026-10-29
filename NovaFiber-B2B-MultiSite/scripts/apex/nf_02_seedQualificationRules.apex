// NovaFiber Product Qualification rules (technology-based), evaluated by the
// NF_Serviceability_Qualification procedure through its decision table:
//   ProductId = ...  AND  NF_AccessTechnology__c = <address technology>  AND  NF_MinDownloadMbps__c <= <address max speed>
// Re-runnable: replaces the NFR rules. Refresh the decision table afterwards.
List<List<Object>> defs = new List<List<Object>>{
    new List<Object>{ 'NFR-INT-300', 'Fiber', 300 },
    new List<Object>{ 'NFR-INT-1G', 'Fiber', 1000 },
    new List<Object>{ 'NFR-INT-2G', 'Fiber', 2000 },
    new List<Object>{ 'NFR-INT-DSL50', 'Copper', 50 },
    new List<Object>{ 'NFR-INT-DSL100', 'Copper', 100 },
    new List<Object>{ 'NFR-INT-5G', '5G FWA', 250 },
    new List<Object>{ 'NFR-TV-ESS', 'Fiber', 0 },
    new List<Object>{ 'NFR-TV-PRM', 'Fiber', 0 }
};
for (String mobile : new List<String>{ 'NFR-MOB-ESS', 'NFR-MOB-UNL' }) {
    for (String tech : new List<String>{ 'Fiber', 'Copper', '5G FWA', 'None' }) defs.add(new List<Object>{ mobile, tech, 0 });
}
Set<String> codes = new Set<String>();
for (List<Object> d : defs) codes.add((String) d[0]);
Map<String, Id> ids = new Map<String, Id>();
for (Product2 p : [SELECT Id, ProductCode FROM Product2 WHERE ProductCode IN :codes]) ids.put(p.ProductCode, p.Id);
delete [SELECT Id FROM ProductQualification WHERE Product.ProductCode LIKE 'NFR-%'];
List<ProductQualification> rules = new List<ProductQualification>();
for (List<Object> d : defs) {
    rules.add(new ProductQualification(ProductId = ids.get((String) d[0]), NF_AccessTechnology__c = (String) d[1],
        NF_MinDownloadMbps__c = (Integer) d[2], EffectiveFromDate = Date.newInstance(2026, 1, 1)));
}
insert rules;
System.debug('NF_RULES inserted=' + rules.size());
