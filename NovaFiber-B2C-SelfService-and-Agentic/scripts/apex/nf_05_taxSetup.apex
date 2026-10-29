// NovaFiber tax setup (POC): Revenue Cloud order activation needs a resolvable tax treatment on every
// order item. Creates a non-taxable treatment and an active tax policy and assigns it to the NovaFiber
// products (prices are shown "before taxes"). Idempotent.
LegalEntity le;
List<LegalEntity> les = [SELECT Id FROM LegalEntity WHERE Name = 'NovaFiber Inc.' LIMIT 1];
if (les.isEmpty()) {
    le = new LegalEntity(Name = 'NovaFiber Inc.', Status = 'Active', LegalEntityStreet = '415 Mission St',
        LegalEntityCity = 'San Francisco', LegalEntityState = 'CA', LegalEntityPostalCode = '94105', LegalEntityCountry = 'US');
    insert le;
} else {
    le = les[0];
}

TaxPolicy policy;
List<TaxPolicy> policies = [SELECT Id, Status, DefaultTaxTreatmentId FROM TaxPolicy WHERE Name = 'NovaFiber Tax Policy' LIMIT 1];
if (policies.isEmpty()) {
    policy = new TaxPolicy(Name = 'NovaFiber Tax Policy', Status = 'Draft', TreatmentSelection = 'Default',
        Description = 'NovaFiber POC: residential services quoted before taxes.');
    insert policy;
} else {
    policy = policies[0];
}

List<TaxTreatment> treatments = [SELECT Id, Status FROM TaxTreatment WHERE Name = 'NovaFiber Non-Taxable' LIMIT 1];
TaxTreatment treatment;
if (treatments.isEmpty()) {
    treatment = new TaxTreatment(Name = 'NovaFiber Non-Taxable', TaxPolicyId = policy.Id, LegalEntityId = le.Id,
        IsTaxable = false, Status = 'Draft', Description = 'POC: no tax calculated on NovaFiber services.');
    insert treatment;
} else {
    treatment = treatments[0];
}
if (treatment.Status != 'Active') {
    treatment.Status = 'Active';
    update treatment;
}
if (policy.DefaultTaxTreatmentId != treatment.Id || policy.Status != 'Active') {
    policy.DefaultTaxTreatmentId = treatment.Id;
    policy.Status = 'Active';
    update policy;
}

List<Product2> products = [SELECT Id, ProductCode FROM Product2 WHERE (ProductCode LIKE 'NFR-%' OR ProductCode LIKE 'NF-TP-%') AND TaxPolicyId = null];
for (Product2 p : products) p.TaxPolicyId = policy.Id;
update products;
System.debug('TAX legalEntity=' + le.Id + ' policy=' + policy.Id + ' treatment=' + treatment.Id + ' products updated=' + products.size());
