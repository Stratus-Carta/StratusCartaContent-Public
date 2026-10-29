// NovaFiber Dynamic Revenue Orchestrator configuration (idempotent: existing NovaFiber records are kept).
//
// Decomposition: every NovaFiber commercial plan decomposes into technical products
//   internet (NFR-INT-*)  -> Order Handling, NovaNet Access, Equipment & Installation, NovaBill Subscription
//   TV (NFR-TV-ESS/PRM)   -> Order Handling, Equipment & Installation, NovaBill Subscription
//   mobile (NFR-MOB-*)    -> Order Handling, NovaBill Subscription
// Orchestration: one step group (swimlane) per technical product, all step types, cross-lane dependencies:
//   Order Intake           AutoTask validate -> Milestone Order confirmed -> AutoTask notify
//   Network Provisioning   Callout reserve port (async) -> Milestone -> AutoTask notify ... Callout activate (async,
//                          after installation) -> Milestone Service active -> AutoTask notify
//   Equipment & Install    Callout ship (async) -> Pause until delivered -> AutoTask schedule -> ManualTask technician
//                          -> Milestone Installation complete -> AutoTask notify
//   Billing & Activation   Callout billing account (sync) -> Callout start billing (async, after service active)
//                          -> Milestone Billing started -> StagedAssetize (assets only once billing runs) -> AutoTask activate customer
Id opsUser = UserInfo.getUserId();   // runs automated steps and works the technician task (ops)
Id providerClass = [SELECT Id FROM ApexClass WHERE Name = 'NF_DroCalloutProvider' LIMIT 1].Id;

// ── Technical products ───────────────────────────────────────────────────
Map<String, String> techNames = new Map<String, String>{
    'NF-TP-ORDER' => 'NovaFiber Order Handling (technical)',
    'NF-TP-ACCESS' => 'NovaNet Access Service (technical)',
    'NF-TP-INSTALL' => 'NovaFiber Equipment & Installation (technical)',
    'NF-TP-BILLING' => 'NovaBill Subscription (technical)'
};
Map<String, Product2> tech = new Map<String, Product2>();
for (Product2 p : [SELECT Id, ProductCode FROM Product2 WHERE ProductCode IN :techNames.keySet()]) tech.put(p.ProductCode, p);
TaxPolicy tax = [SELECT Id FROM TaxPolicy WHERE Name = 'NovaFiber Tax Policy' LIMIT 1];
BillingPolicy bill = [SELECT Id FROM BillingPolicy WHERE Name = 'NovaFiber Billing Policy' LIMIT 1];
List<Product2> newTech = new List<Product2>();
for (String code : techNames.keySet()) {
    if (!tech.containsKey(code)) {
        Product2 p = new Product2(Name = techNames.get(code), ProductCode = code, IsActive = true, TaxPolicyId = tax.Id,
            BillingPolicyId = bill.Id, Description = 'Technical product for NovaFiber order decomposition (not sold).');
        newTech.add(p);
        tech.put(code, p);
    }
}
insert newTech;

// ── Decomposition rules ──────────────────────────────────────────────────
Map<String, List<String>> decomposition = new Map<String, List<String>>{
    'NFR-INT-' => new List<String>{ 'NF-TP-ORDER', 'NF-TP-ACCESS', 'NF-TP-INSTALL', 'NF-TP-BILLING' },
    'NFR-TV-' => new List<String>{ 'NF-TP-ORDER', 'NF-TP-INSTALL', 'NF-TP-BILLING' },
    'NFR-MOB-' => new List<String>{ 'NF-TP-ORDER', 'NF-TP-BILLING' }
};
Set<String> existingRules = new Set<String>();
for (ProductFulfillmentDecompRule r : [SELECT SourceProductId, DestinationProductId FROM ProductFulfillmentDecompRule WHERE Name LIKE 'NF %']) {
    existingRules.add(r.SourceProductId + '>' + r.DestinationProductId);
}
List<ProductFulfillmentDecompRule> rules = new List<ProductFulfillmentDecompRule>();
for (Product2 root : [SELECT Id, ProductCode, Name FROM Product2 WHERE ProductCode IN
        ('NFR-INT-300', 'NFR-INT-1G', 'NFR-INT-2G', 'NFR-INT-5G', 'NFR-INT-DSL50', 'NFR-INT-DSL100',
         'NFR-TV-ESS', 'NFR-TV-PRM', 'NFR-MOB-ESS', 'NFR-MOB-UNL')]) {
    String family = root.ProductCode.startsWith('NFR-INT-') ? 'NFR-INT-' : root.ProductCode.startsWith('NFR-TV-') ? 'NFR-TV-' : 'NFR-MOB-';
    Integer priority = 1;
    for (String code : decomposition.get(family)) {
        Id dest = tech.get(code).Id;
        if (!existingRules.contains(root.Id + '>' + dest)) {
            rules.add(new ProductFulfillmentDecompRule(Name = ('NF ' + root.ProductCode + ' > ' + code).left(80),
                SourceProductId = root.Id, DestinationProductId = dest, Priority = priority));
        }
        priority++;
    }
}
insert rules;

// ── Integration definitions (created by nf_07a_integrationDefs.apex over REST: no DML on IntegrationProviderDef) ──
Map<String, Id> defIds = new Map<String, Id>();
for (IntegrationProviderDef d : [SELECT Id, DeveloperName FROM IntegrationProviderDef WHERE DeveloperName LIKE 'NF_%']) defIds.put(d.DeveloperName, d.Id);
if (defIds.size() < 5) throw new NF_JourneyModels.JourneyException('Run scripts/apex/nf_07a_integrationDefs.apex first.');

// ── Step groups (swimlanes), steps and dependencies ──────────────────────
List<String> groupNames = new List<String>{ 'NF Order Intake', 'NF Network Provisioning', 'NF Equipment & Installation', 'NF Billing & Activation' };
Map<String, FulfillmentStepDefinitionGroup> groups = new Map<String, FulfillmentStepDefinitionGroup>();
for (FulfillmentStepDefinitionGroup g : [SELECT Id, Name FROM FulfillmentStepDefinitionGroup WHERE Name IN :groupNames]) groups.put(g.Name, g);
for (String n : groupNames) {
    if (!groups.containsKey(n)) {
        FulfillmentStepDefinitionGroup g = new FulfillmentStepDefinitionGroup(Name = n, UsageType = 'Fulfillment');
        insert g;
        groups.put(n, g);
    }
}

// key => group, step type, name, flow or integration definition
List<List<String>> steps = new List<List<String>>{
    new List<String>{ 'S11', 'NF Order Intake', 'AutoTask', 'Validate order', 'NF_DRO_Validate_Order' },
    new List<String>{ 'S12', 'NF Order Intake', 'Milestone', 'Order confirmed', '' },
    new List<String>{ 'S13', 'NF Order Intake', 'AutoTask', 'Notify customer - order confirmed', 'NF_DRO_Milestone_Order_Confirmed' },
    new List<String>{ 'S21', 'NF Network Provisioning', 'Callout', 'Reserve network port', 'NF_Provisioning_Reserve' },
    new List<String>{ 'S22', 'NF Network Provisioning', 'Milestone', 'Network reserved', '' },
    new List<String>{ 'S23', 'NF Network Provisioning', 'AutoTask', 'Notify customer - network reserved', 'NF_DRO_Milestone_Network_Reserved' },
    new List<String>{ 'S24', 'NF Network Provisioning', 'Callout', 'Activate service', 'NF_Provisioning_Activate' },
    new List<String>{ 'S25', 'NF Network Provisioning', 'Milestone', 'Service active', '' },
    new List<String>{ 'S26', 'NF Network Provisioning', 'AutoTask', 'Notify customer - service active', 'NF_DRO_Milestone_Service_Active' },
    new List<String>{ 'S31', 'NF Equipment & Installation', 'Callout', 'Ship equipment', 'NF_Logistics_Ship' },
    new List<String>{ 'S32', 'NF Equipment & Installation', 'Pause', 'Awaiting equipment delivery', '' },
    new List<String>{ 'S33', 'NF Equipment & Installation', 'AutoTask', 'Schedule technician visit', 'NF_DRO_Milestone_Installation_Scheduled' },
    new List<String>{ 'S34', 'NF Equipment & Installation', 'ManualTask', 'Technician installation', '' },
    new List<String>{ 'S35', 'NF Equipment & Installation', 'Milestone', 'Installation complete', '' },
    new List<String>{ 'S36', 'NF Equipment & Installation', 'AutoTask', 'Notify customer - installation complete', 'NF_DRO_Milestone_Installation_Complete' },
    new List<String>{ 'S41', 'NF Billing & Activation', 'Callout', 'Create billing account', 'NF_Billing_Account' },
    new List<String>{ 'S42', 'NF Billing & Activation', 'StagedAssetize', 'Create customer assets', '' },
    new List<String>{ 'S43', 'NF Billing & Activation', 'Callout', 'Start subscription billing', 'NF_Billing_Subscription' },
    new List<String>{ 'S44', 'NF Billing & Activation', 'Milestone', 'Billing started', '' },
    new List<String>{ 'S45', 'NF Billing & Activation', 'AutoTask', 'Activate customer', 'NF_DRO_Milestone_Active' }
};
Map<String, FulfillmentStepDefinition> defsByKey = new Map<String, FulfillmentStepDefinition>();
Map<String, FulfillmentStepDefinition> existingSteps = new Map<String, FulfillmentStepDefinition>();
for (FulfillmentStepDefinition s : [SELECT Id, Name, StepDefinitionGroup.Name FROM FulfillmentStepDefinition WHERE StepDefinitionGroupId IN :new Map<String, FulfillmentStepDefinitionGroup>(groups).values()]) {
    existingSteps.put(s.StepDefinitionGroup.Name + '|' + s.Name, s);
}
List<FulfillmentStepDefinition> newSteps = new List<FulfillmentStepDefinition>();
for (List<String> s : steps) {
    FulfillmentStepDefinition d = existingSteps.get(s[1] + '|' + s[3]);
    if (d == null) {
        d = new FulfillmentStepDefinition(Name = s[3], StepDefinitionGroupId = groups.get(s[1]).Id, StepType = s[2], Scope = 'Plan',
            UsageType = 'Fulfillment', Description = 'NovaFiber ' + s[1].removeStart('NF ') + ' lane');
        if (s[2] == 'AutoTask') { d.FlowDefinitionName = s[4]; d.RunAsUserId = opsUser; }
        if (s[2] == 'Callout') { d.IntegrationDefinitionNameId = defIds.get(s[4]); d.RunAsUserId = opsUser; }
        if (s[2] == 'ManualTask') d.AssignedToId = opsUser;
        if (s[2] == 'Pause') { d.ExecuteOn = 'PreviousStepExecutionDate'; d.DelayOf = 1; d.DelayUnit = 'Minutes'; }   // carrier transit: NovaShip delivers ~1 minute after the shipment (Minutes is the smallest unit)
        newSteps.add(d);
    }
    defsByKey.put(s[0], d);
}
insert newSteps;

// step => steps it depends on
Map<String, List<String>> deps = new Map<String, List<String>>{
    'S12' => new List<String>{ 'S11' }, 'S13' => new List<String>{ 'S12' },
    'S21' => new List<String>{ 'S12' }, 'S22' => new List<String>{ 'S21' }, 'S23' => new List<String>{ 'S22' },
    'S24' => new List<String>{ 'S35' }, 'S25' => new List<String>{ 'S24' }, 'S26' => new List<String>{ 'S25' },
    'S31' => new List<String>{ 'S12' }, 'S32' => new List<String>{ 'S31' }, 'S33' => new List<String>{ 'S32', 'S22' },
    'S34' => new List<String>{ 'S33' }, 'S35' => new List<String>{ 'S34' }, 'S36' => new List<String>{ 'S35' },
    'S41' => new List<String>{ 'S12' }, 'S43' => new List<String>{ 'S25', 'S41' }, 'S42' => new List<String>{ 'S44' },
    'S44' => new List<String>{ 'S43' }, 'S45' => new List<String>{ 'S42', 'S26' }
};
Set<String> existingDeps = new Set<String>();
for (FulfillmentStepDependencyDef dd : [SELECT FulfillmentStepDefinitionId, DependsOnStepDefinitionId FROM FulfillmentStepDependencyDef
        WHERE FulfillmentStepDefinitionId IN :new Map<Id, FulfillmentStepDefinition>(defsByKey.values()).keySet()]) {
    existingDeps.add(dd.FulfillmentStepDefinitionId + '>' + dd.DependsOnStepDefinitionId);
}
List<FulfillmentStepDependencyDef> newDeps = new List<FulfillmentStepDependencyDef>();
for (String key : deps.keySet()) {
    for (String prerequisite : deps.get(key)) {
        FulfillmentStepDefinition a = defsByKey.get(key);
        FulfillmentStepDefinition b = defsByKey.get(prerequisite);
        if (existingDeps.contains(a.Id + '>' + b.Id)) continue;
        newDeps.add(new FulfillmentStepDependencyDef(Name = (a.Name + ' after ' + b.Name).left(80),
            FulfillmentStepDefinitionId = a.Id, DependsOnStepDefinitionId = b.Id, DependencyScope = 'Plan'));
    }
}
insert newDeps;

// ── Fulfillment scenarios: technical product -> swimlane ─────────────────
Map<String, String> scenarioGroup = new Map<String, String>{
    'NF-TP-ORDER' => 'NF Order Intake', 'NF-TP-ACCESS' => 'NF Network Provisioning',
    'NF-TP-INSTALL' => 'NF Equipment & Installation', 'NF-TP-BILLING' => 'NF Billing & Activation'
};
Set<Id> scenarioProducts = new Set<Id>();
for (ProductFulfillmentScenario s : [SELECT ProductId FROM ProductFulfillmentScenario WHERE Name LIKE 'NF %']) scenarioProducts.add(s.ProductId);
List<ProductFulfillmentScenario> scenarios = new List<ProductFulfillmentScenario>();
for (String code : scenarioGroup.keySet()) {
    if (scenarioProducts.contains(tech.get(code).Id)) continue;
    scenarios.add(new ProductFulfillmentScenario(Name = ('NF ' + scenarioGroup.get(code).removeStart('NF ') + ' Scenario').left(80),
        ProductId = tech.get(code).Id, FulfillmentStepDefnGroupId = groups.get(scenarioGroup.get(code)).Id, Action = 'Add', UsageType = 'Fulfillment'));
}
insert scenarios;

// ── Fulfillment workspace (visual designer: the four swimlanes) ──────────
List<FulfillmentWorkspace> ws = [SELECT Id FROM FulfillmentWorkspace WHERE Name = 'NovaFiber Order Fulfillment' LIMIT 1];
if (ws.isEmpty()) {
    FulfillmentWorkspace w = new FulfillmentWorkspace(Name = 'NovaFiber Order Fulfillment',
        Description = 'NovaFiber residential order orchestration: order intake, network provisioning, equipment and installation, billing and activation.');
    insert w;
    List<FulfillmentWorkspaceItem> items = new List<FulfillmentWorkspaceItem>();
    for (Integer i = 0; i < groupNames.size(); i++) {
        items.add(new FulfillmentWorkspaceItem(FulfillmentWorkspaceId = w.Id, FulfillmentStepDefinitionGroupId = groups.get(groupNames[i]).Id, ShowOrder = i + 1));
    }
    insert items;
}
System.debug('DRO tech=' + newTech.size() + ' rules=' + rules.size() + ' steps=' + newSteps.size() + ' deps=' + newDeps.size()
    + ' scenarios=' + scenarios.size() + ' integrationDefs=' + defIds.size());
