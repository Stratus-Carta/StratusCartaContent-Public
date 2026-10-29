// NovaFiber billing setup (POC): Revenue Cloud order activation needs a billing treatment. Creates a
// "bill monthly in advance" billing policy and treatment and assigns the policy to the NovaFiber products.
// Idempotent.
BillingPolicy policy;
List<BillingPolicy> policies = [SELECT Id, Status, DefaultBillingTreatmentId FROM BillingPolicy WHERE Name = 'NovaFiber Billing Policy' LIMIT 1];
if (policies.isEmpty()) {
    policy = new BillingPolicy(Name = 'NovaFiber Billing Policy', Status = 'Draft', BillingTreatmentSelection = 'Default',
        Description = 'NovaFiber POC: residential services billed monthly in advance.');
    insert policy;
} else {
    policy = policies[0];
}

BillingTreatment treatment;
List<BillingTreatment> treatments = [SELECT Id, Status FROM BillingTreatment WHERE Name = 'NovaFiber Monthly In Advance' LIMIT 1];
if (treatments.isEmpty()) {
    LegalEntity le = [SELECT Id FROM LegalEntity WHERE Name = 'NovaFiber Inc.' LIMIT 1];
    treatment = new BillingTreatment(Name = 'NovaFiber Monthly In Advance', BillingPolicyId = policy.Id, LegalEntityId = le.Id,
        Status = 'Draft', ExcludeFromBilling = 'No', Description = 'Bill the full amount in advance each period.');
    insert treatment;
    insert new BillingTreatmentItem(Name = 'Full amount in advance', BillingTreatmentId = treatment.Id, Status = 'Active',
        ProcessingOrder = 1, Type = 'Remainder', BillingType = 'Advance', Sequencing = 'Manual',
        Controller = 'BillingScheduleGroup', Handling0Amount = 'CreateInvoice');
} else {
    treatment = treatments[0];
}
if (treatment.Status != 'Active') {
    treatment.Status = 'Active';
    update treatment;
}
if (policy.DefaultBillingTreatmentId != treatment.Id || policy.Status != 'Active') {
    policy.DefaultBillingTreatmentId = treatment.Id;
    policy.Status = 'Active';
    update policy;
}

List<Product2> products = [SELECT Id FROM Product2 WHERE (ProductCode LIKE 'NFR-%' OR ProductCode LIKE 'NF-TP-%') AND BillingPolicyId = null];
for (Product2 p : products) p.BillingPolicyId = policy.Id;
update products;
System.debug('BILLING policy=' + policy.Id + ' treatment=' + treatment.Id + ' products updated=' + products.size());
