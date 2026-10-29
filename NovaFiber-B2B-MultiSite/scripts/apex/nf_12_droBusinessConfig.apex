// NovaFiber Business (B2B) Dynamic Revenue Orchestrator configuration — idempotent; residential config untouched.
// Run after nf_11_seedBusinessCatalog.apex and nf_07a_integrationDefs.apex (reuses its 5 integration definitions).
//
// Decomposition: every business offer decomposes into technical products (NF-TPB-*)
//   Business Fiber (NFB-FIB-*)       -> Order Handling, Access, Equipment & Installation, Billing
//   Dedicated Internet (NFB-DIA-*)   -> Order Handling, Access, Dedicated Circuit, Billing
//   SD-WAN (NFB-SDW-*)               -> Order Handling, Equipment & Installation, Managed Services, Billing
//   Voice (NFB-VOC-*)                -> Order Handling, Managed Services, Billing
//
// Orchestration: six swimlanes. Order Intake and Billing run once per order (Plan scope); the four site lanes run
// once per sold bundle (Bundle scope), so a multi-site order gets each site's survey, build, installation and
// activation separately. Dependencies within a site use Bundle scope; hand-offs to and from the order use Plan scope.
//   Order Intake        AutoTask validate -> ManualTask credit & contract review -> Milestone order confirmed -> AutoTask notify
//   Access Provisioning Callout reserve capacity -> Milestone -> AutoTask notify ... Callout activate (after installation
//                       or circuit) -> Milestone service active -> AutoTask notify
//   Dedicated Circuit   ManualTask site survey -> Pause fiber build window -> ManualTask circuit turn-up & testing -> Milestone
//   Equipment & Install Callout ship -> Pause delivery -> AutoTask schedule engineer -> ManualTask engineer installation
//                       -> Milestone installation complete -> AutoTask notify
//   Managed Services    ManualTask service design & configuration -> Milestone services configured
//   Billing & Activation Callout billing account -> Callout start billing (after every site is live) -> Milestone
//                       -> StagedAssetize -> AutoTask activate customer
Id opsUser = UserInfo.getUserId();   // runs automated steps and works the manual tasks (ops)

// ── Technical products ───────────────────────────────────────────────────
Map<String, String> techNames = new Map<String, String>{
    'NF-TPB-ORDER' => 'NovaFiber Business Order Handling (technical)',
    'NF-TPB-ACCESS' => 'NovaNet Business Access (technical)',
    'NF-TPB-CIRCUIT' => 'NovaNet Dedicated Circuit (technical)',
    'NF-TPB-INSTALL' => 'NovaFiber Business Equipment & Installation (technical)',
    'NF-TPB-SERVICES' => 'NovaFiber Managed Services (technical)',
    'NF-TPB-BILLING' => 'NovaBill Business Subscription (technical)'
};
Map<String, Product2> tech = new Map<String, Product2>();
for (Product2 p : [SELECT Id, ProductCode FROM Product2 WHERE ProductCode IN :techNames.keySet()]) tech.put(p.ProductCode, p);
TaxPolicy tax = [SELECT Id FROM TaxPolicy WHERE Name = 'NovaFiber Tax Policy' LIMIT 1];
BillingPolicy bill = [SELECT Id FROM BillingPolicy WHERE Name = 'NovaFiber Billing Policy' LIMIT 1];
List<Product2> newTech = new List<Product2>();
for (String code : techNames.keySet()) {
    if (!tech.containsKey(code)) {
        Product2 p = new Product2(Name = techNames.get(code), ProductCode = code, IsActive = true, TaxPolicyId = tax.Id,
            BillingPolicyId = bill.Id, Family = 'NovaFiber Business Technical',
            Description = 'Technical product for NovaFiber business order decomposition (not sold).');
        newTech.add(p);
        tech.put(code, p);
    }
}
insert newTech;

// ── Decomposition rules ──────────────────────────────────────────────────
Map<String, List<String>> decomposition = new Map<String, List<String>>{
    'NFB-FIB-' => new List<String>{ 'NF-TPB-ORDER', 'NF-TPB-ACCESS', 'NF-TPB-INSTALL', 'NF-TPB-BILLING' },
    'NFB-DIA-' => new List<String>{ 'NF-TPB-ORDER', 'NF-TPB-ACCESS', 'NF-TPB-CIRCUIT', 'NF-TPB-BILLING' },
    'NFB-SDW-' => new List<String>{ 'NF-TPB-ORDER', 'NF-TPB-INSTALL', 'NF-TPB-SERVICES', 'NF-TPB-BILLING' },
    'NFB-VOC-' => new List<String>{ 'NF-TPB-ORDER', 'NF-TPB-SERVICES', 'NF-TPB-BILLING' }
};
Set<String> existingRules = new Set<String>();
for (ProductFulfillmentDecompRule r : [SELECT SourceProductId, DestinationProductId FROM ProductFulfillmentDecompRule WHERE Name LIKE 'NFB %']) {
    existingRules.add(r.SourceProductId + '>' + r.DestinationProductId);
}
List<ProductFulfillmentDecompRule> rules = new List<ProductFulfillmentDecompRule>();
for (Product2 root : [SELECT Id, ProductCode FROM Product2 WHERE Type = 'Bundle' AND (ProductCode LIKE 'NFB-FIB-%'
        OR ProductCode LIKE 'NFB-DIA-%' OR ProductCode LIKE 'NFB-SDW-%' OR ProductCode LIKE 'NFB-VOC-%')]) {
    Integer priority = 1;
    for (String code : decomposition.get(root.ProductCode.left(8))) {
        Id dest = tech.get(code).Id;
        if (!existingRules.contains(root.Id + '>' + dest)) {
            rules.add(new ProductFulfillmentDecompRule(Name = ('NFB ' + root.ProductCode + ' > ' + code).left(80),
                SourceProductId = root.Id, DestinationProductId = dest, Priority = priority));
        }
        priority++;
    }
}
insert rules;

// ── Integration definitions (shared with residential; nf_07a_integrationDefs.apex) ──
Map<String, Id> defIds = new Map<String, Id>();
for (IntegrationProviderDef d : [SELECT Id, DeveloperName FROM IntegrationProviderDef WHERE DeveloperName LIKE 'NF_%']) defIds.put(d.DeveloperName, d.Id);
if (defIds.size() < 5) throw new NF_JourneyModels.JourneyException('Run scripts/apex/nf_07a_integrationDefs.apex first.');

// ── Step groups (swimlanes) ──────────────────────────────────────────────
List<String> groupNames = new List<String>{ 'NFB Order Intake', 'NFB Access Provisioning', 'NFB Dedicated Circuit',
    'NFB Equipment & Installation', 'NFB Managed Services', 'NFB Billing & Activation' };
Map<String, FulfillmentStepDefinitionGroup> groups = new Map<String, FulfillmentStepDefinitionGroup>();
for (FulfillmentStepDefinitionGroup g : [SELECT Id, Name FROM FulfillmentStepDefinitionGroup WHERE Name IN :groupNames]) groups.put(g.Name, g);
for (String n : groupNames) {
    if (!groups.containsKey(n)) {
        FulfillmentStepDefinitionGroup g = new FulfillmentStepDefinitionGroup(Name = n, UsageType = 'Fulfillment');
        insert g;
        groups.put(n, g);
    }
}
// Once per order vs once per sold bundle (site)
Map<String, String> laneScope = new Map<String, String>{
    'NFB Order Intake' => 'Plan', 'NFB Billing & Activation' => 'Plan',
    'NFB Access Provisioning' => 'Bundle', 'NFB Dedicated Circuit' => 'Bundle',
    'NFB Equipment & Installation' => 'Bundle', 'NFB Managed Services' => 'Bundle'
};

// key => group, step type, name, flow or integration definition
List<List<String>> steps = new List<List<String>>{
    new List<String>{ 'B11', 'NFB Order Intake', 'AutoTask', 'Validate order', 'NF_DRO_Validate_Order' },
    new List<String>{ 'B12', 'NFB Order Intake', 'ManualTask', 'Credit and contract review', '' },
    new List<String>{ 'B13', 'NFB Order Intake', 'Milestone', 'Order confirmed', '' },
    new List<String>{ 'B14', 'NFB Order Intake', 'AutoTask', 'Notify customer - order confirmed', 'NF_DRO_Milestone_Order_Confirmed' },
    new List<String>{ 'B21', 'NFB Access Provisioning', 'Callout', 'Reserve network capacity', 'NF_Provisioning_Reserve' },
    new List<String>{ 'B22', 'NFB Access Provisioning', 'Milestone', 'Capacity reserved', '' },
    new List<String>{ 'B23', 'NFB Access Provisioning', 'AutoTask', 'Notify customer - network reserved', 'NF_DRO_Milestone_Network_Reserved' },
    new List<String>{ 'B24', 'NFB Access Provisioning', 'Callout', 'Activate site service', 'NF_Provisioning_Activate' },
    new List<String>{ 'B25', 'NFB Access Provisioning', 'Milestone', 'Site service active', '' },
    new List<String>{ 'B26', 'NFB Access Provisioning', 'AutoTask', 'Notify customer - service active', 'NF_DRO_Milestone_Service_Active' },
    new List<String>{ 'B31', 'NFB Dedicated Circuit', 'ManualTask', 'Site survey', '' },
    new List<String>{ 'B32', 'NFB Dedicated Circuit', 'Pause', 'Fiber build window', '' },
    new List<String>{ 'B33', 'NFB Dedicated Circuit', 'ManualTask', 'Circuit turn-up and testing', '' },
    new List<String>{ 'B34', 'NFB Dedicated Circuit', 'Milestone', 'Circuit ready', '' },
    new List<String>{ 'B41', 'NFB Equipment & Installation', 'Callout', 'Ship equipment', 'NF_Logistics_Ship' },
    new List<String>{ 'B42', 'NFB Equipment & Installation', 'Pause', 'Awaiting equipment delivery', '' },
    new List<String>{ 'B43', 'NFB Equipment & Installation', 'AutoTask', 'Schedule engineer visit', 'NF_DRO_Milestone_Installation_Scheduled' },
    new List<String>{ 'B44', 'NFB Equipment & Installation', 'ManualTask', 'Engineer installation', '' },
    new List<String>{ 'B45', 'NFB Equipment & Installation', 'Milestone', 'Installation complete', '' },
    new List<String>{ 'B46', 'NFB Equipment & Installation', 'AutoTask', 'Notify customer - installation complete', 'NF_DRO_Milestone_Installation_Complete' },
    new List<String>{ 'B51', 'NFB Managed Services', 'ManualTask', 'Service design and configuration', '' },
    new List<String>{ 'B52', 'NFB Managed Services', 'Milestone', 'Services configured', '' },
    new List<String>{ 'B61', 'NFB Billing & Activation', 'Callout', 'Create billing account', 'NF_Billing_Account' },
    new List<String>{ 'B62', 'NFB Billing & Activation', 'Callout', 'Start subscription billing', 'NF_Billing_Subscription' },
    new List<String>{ 'B63', 'NFB Billing & Activation', 'Milestone', 'Billing started', '' },
    new List<String>{ 'B64', 'NFB Billing & Activation', 'StagedAssetize', 'Create customer assets', '' },
    new List<String>{ 'B65', 'NFB Billing & Activation', 'AutoTask', 'Activate customer', 'NF_DRO_Milestone_Active' }
};
Map<String, FulfillmentStepDefinition> defsByKey = new Map<String, FulfillmentStepDefinition>();
Map<String, FulfillmentStepDefinition> existingSteps = new Map<String, FulfillmentStepDefinition>();
for (FulfillmentStepDefinition s : [SELECT Id, Name, StepDefinitionGroup.Name FROM FulfillmentStepDefinition
        WHERE StepDefinitionGroupId IN :new Map<String, FulfillmentStepDefinitionGroup>(groups).values()]) {
    existingSteps.put(s.StepDefinitionGroup.Name + '|' + s.Name, s);
}
List<FulfillmentStepDefinition> newSteps = new List<FulfillmentStepDefinition>();
for (List<String> s : steps) {
    FulfillmentStepDefinition d = existingSteps.get(s[1] + '|' + s[3]);
    if (d == null) {
        d = new FulfillmentStepDefinition(Name = s[3], StepDefinitionGroupId = groups.get(s[1]).Id, StepType = s[2],
            Scope = laneScope.get(s[1]), UsageType = 'Fulfillment', Description = 'NovaFiber Business ' + s[1].removeStart('NFB ') + ' lane');
        if (s[2] == 'AutoTask') { d.FlowDefinitionName = s[4]; d.RunAsUserId = opsUser; }
        if (s[2] == 'Callout') { d.IntegrationDefinitionNameId = defIds.get(s[4]); d.RunAsUserId = opsUser; }
        if (s[2] == 'ManualTask') d.AssignedToId = opsUser;
        if (s[2] == 'Pause') { d.ExecuteOn = 'PreviousStepExecutionDate'; d.DelayOf = 1; d.DelayUnit = 'Minutes'; }   // Minutes is the smallest unit
        newSteps.add(d);
    }
    defsByKey.put(s[0], d);
}
insert newSteps;

// step => prerequisites; a prerequisite in the same site lane family is linked per bundle, otherwise per plan
Map<String, List<String>> deps = new Map<String, List<String>>{
    'B12' => new List<String>{ 'B11' }, 'B13' => new List<String>{ 'B12' }, 'B14' => new List<String>{ 'B13' },
    'B21' => new List<String>{ 'B13' }, 'B22' => new List<String>{ 'B21' }, 'B23' => new List<String>{ 'B22' },
    'B24' => new List<String>{ 'B45', 'B34' }, 'B25' => new List<String>{ 'B24' }, 'B26' => new List<String>{ 'B25' },
    'B31' => new List<String>{ 'B13' }, 'B32' => new List<String>{ 'B31' }, 'B33' => new List<String>{ 'B32', 'B22' },
    'B34' => new List<String>{ 'B33' },
    'B41' => new List<String>{ 'B13' }, 'B42' => new List<String>{ 'B41' }, 'B43' => new List<String>{ 'B42', 'B22' },
    'B44' => new List<String>{ 'B43' }, 'B45' => new List<String>{ 'B44' }, 'B46' => new List<String>{ 'B45' },
    'B51' => new List<String>{ 'B13' }, 'B52' => new List<String>{ 'B51' },
    'B61' => new List<String>{ 'B13' }, 'B62' => new List<String>{ 'B61', 'B25', 'B52' }, 'B63' => new List<String>{ 'B62' },
    'B64' => new List<String>{ 'B63' }, 'B65' => new List<String>{ 'B64', 'B26' }
};
Set<String> existingDeps = new Set<String>();
for (FulfillmentStepDependencyDef dd : [SELECT FulfillmentStepDefinitionId, DependsOnStepDefinitionId FROM FulfillmentStepDependencyDef
        WHERE FulfillmentStepDefinitionId IN :new Map<Id, FulfillmentStepDefinition>(defsByKey.values()).keySet()]) {
    existingDeps.add(dd.FulfillmentStepDefinitionId + '>' + dd.DependsOnStepDefinitionId);
}
Map<String, String> laneOf = new Map<String, String>();
for (List<String> s : steps) laneOf.put(s[0], s[1]);
List<FulfillmentStepDependencyDef> newDeps = new List<FulfillmentStepDependencyDef>();
for (String key : deps.keySet()) {
    for (String prerequisite : deps.get(key)) {
        FulfillmentStepDefinition a = defsByKey.get(key);
        FulfillmentStepDefinition b = defsByKey.get(prerequisite);
        if (existingDeps.contains(a.Id + '>' + b.Id)) continue;
        Boolean bothPerSite = laneScope.get(laneOf.get(key)) == 'Bundle' && laneScope.get(laneOf.get(prerequisite)) == 'Bundle';
        newDeps.add(new FulfillmentStepDependencyDef(Name = (a.Name + ' after ' + b.Name).left(80),
            FulfillmentStepDefinitionId = a.Id, DependsOnStepDefinitionId = b.Id, DependencyScope = bothPerSite ? 'Bundle' : 'Plan'));
    }
}
insert newDeps;

// ── Fulfillment scenarios: technical product -> swimlane ─────────────────
Map<String, String> scenarioGroup = new Map<String, String>{
    'NF-TPB-ORDER' => 'NFB Order Intake', 'NF-TPB-ACCESS' => 'NFB Access Provisioning', 'NF-TPB-CIRCUIT' => 'NFB Dedicated Circuit',
    'NF-TPB-INSTALL' => 'NFB Equipment & Installation', 'NF-TPB-SERVICES' => 'NFB Managed Services', 'NF-TPB-BILLING' => 'NFB Billing & Activation'
};
Set<Id> scenarioProducts = new Set<Id>();
for (ProductFulfillmentScenario s : [SELECT ProductId FROM ProductFulfillmentScenario WHERE Name LIKE 'NFB %']) scenarioProducts.add(s.ProductId);
List<ProductFulfillmentScenario> scenarios = new List<ProductFulfillmentScenario>();
for (String code : scenarioGroup.keySet()) {
    if (scenarioProducts.contains(tech.get(code).Id)) continue;
    scenarios.add(new ProductFulfillmentScenario(Name = ('NFB ' + scenarioGroup.get(code).removeStart('NFB ') + ' Scenario').left(80),
        ProductId = tech.get(code).Id, FulfillmentStepDefnGroupId = groups.get(scenarioGroup.get(code)).Id, Action = 'Add', UsageType = 'Fulfillment'));
}
insert scenarios;

// ── Fulfillment workspace (visual designer: the six swimlanes) ───────────
List<FulfillmentWorkspace> ws = [SELECT Id FROM FulfillmentWorkspace WHERE Name = 'NovaFiber Business Fulfillment' LIMIT 1];
if (ws.isEmpty()) {
    FulfillmentWorkspace w = new FulfillmentWorkspace(Name = 'NovaFiber Business Fulfillment',
        Description = 'NovaFiber business (multi-site) orchestration: order intake, access provisioning, dedicated circuits, equipment and installation, managed services, billing and activation.');
    insert w;
    List<FulfillmentWorkspaceItem> items = new List<FulfillmentWorkspaceItem>();
    for (Integer i = 0; i < groupNames.size(); i++) {
        items.add(new FulfillmentWorkspaceItem(FulfillmentWorkspaceId = w.Id, FulfillmentStepDefinitionGroupId = groups.get(groupNames[i]).Id, ShowOrder = i + 1));
    }
    insert items;
}
System.debug('NFB_DRO tech=' + newTech.size() + ' rules=' + rules.size() + ' steps=' + newSteps.size() + ' deps=' + newDeps.size()
    + ' scenarios=' + scenarios.size() + ' integrationDefs=' + defIds.size());
