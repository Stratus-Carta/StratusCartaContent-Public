// NovaFiber Business catalog seed (B2B, used by multi-site quoting) — idempotent.
// Creates products (NFB-*), selling model options, standard price book entries, the "NovaFiber Business"
// catalog (NF_BIZ) + categories, bundle groups/components, and the ProductQualification rules that the
// NF_Serviceability_Qualification procedure evaluates (technology + minimum speed at the address).
// Re-running updates products/prices and rebuilds groups, components and NFB rules.
// Afterwards: run nf_08_seedLocationPrices.apex (state prices) and refresh the decision tables
// Price_Book_Entry_Decision_Table_v2, NF_Serviceability_Qualification and LocationBasedDecisionTable.

Id stdPb = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
Id psmMonthly = [SELECT Id FROM ProductSellingModel WHERE Name = 'Evergreen - Monthly' LIMIT 1].Id;
Id psmOneTime = [SELECT Id FROM ProductSellingModel WHERE Name = 'One-Time' LIMIT 1].Id;
Id proration  = [SELECT Id FROM ProrationPolicy WHERE Name = 'Default Proration Policy' LIMIT 1].Id;
Id bundleRel  = [SELECT Id FROM ProductRelationshipType WHERE MainProductRoleCat = 'Bundle' AND AssociatedProductRoleCat = 'BundleComponent' LIMIT 1].Id;
// Same tax and billing treatments as the residential products, so business orders can be activated.
List<TaxPolicy> taxPolicies = [SELECT Id FROM TaxPolicy WHERE Name = 'NovaFiber Tax Policy' LIMIT 1];
List<BillingPolicy> billingPolicies = [SELECT Id FROM BillingPolicy WHERE Name = 'NovaFiber Billing Policy' LIMIT 1];

// code, name, type(Bundle|''), oneTime?, price, tech, down, up, category, order, featured, tagline, highlights, description
List<List<Object>> defs = new List<List<Object>>{
    // ── Business Fiber (shared fiber, business-grade support)
    new List<Object>{'NFB-FIB-500','Business Fiber 500','Bundle',false,129.00,'Fiber',500,500,'FIBER',10,false,
        'Symmetrical fiber for offices and stores.',
        'Symmetrical 500 Mbps\nBusiness gateway included\nNext-business-day repair',
        'Business fiber internet, 500/500 Mbps.'},
    new List<Object>{'NFB-FIB-1G','Business Fiber 1 Gig','Bundle',false,179.00,'Fiber',1000,1000,'FIBER',20,true,
        'Gigabit fiber for busy teams and cloud apps.',
        'Symmetrical 1 Gbps\nBusiness gateway included\nPriority repair, 8-hour target',
        'Business fiber internet, 1000/1000 Mbps.'},
    new List<Object>{'NFB-FIB-2G','Business Fiber 2 Gig','Bundle',false,249.00,'Fiber',2000,2000,'FIBER',30,false,
        'Multi-gig fiber for media and data-heavy sites.',
        'Symmetrical 2 Gbps\nBusiness gateway included\nPriority repair, 8-hour target',
        'Business fiber internet, 2000/2000 Mbps.'},
    // ── Dedicated Internet Access (uncontended, SLA-backed)
    new List<Object>{'NFB-DIA-100','Dedicated Internet 100 Mbps','Bundle',false,450.00,'Fiber',100,100,'DIA',10,false,
        'Uncontended bandwidth with a 99.95% availability SLA.',
        'Dedicated 100 Mbps, symmetrical\n99.95% availability SLA\nManaged edge router included',
        'Dedicated internet access, 100 Mbps.'},
    new List<Object>{'NFB-DIA-1G','Dedicated Internet 1 Gbps','Bundle',false,1150.00,'Fiber',1000,1000,'DIA',20,true,
        'Guaranteed gigabit for headquarters and data rooms.',
        'Dedicated 1 Gbps, symmetrical\n99.95% availability SLA\nManaged edge router included',
        'Dedicated internet access, 1 Gbps.'},
    new List<Object>{'NFB-DIA-10G','Dedicated Internet 10 Gbps','Bundle',false,3900.00,'Fiber',10000,10000,'DIA',30,false,
        'Carrier-grade capacity for data centres and campuses.',
        'Dedicated 10 Gbps, symmetrical\n99.99% availability SLA\nManaged edge router included',
        'Dedicated internet access, 10 Gbps.'},
    // ── SD-WAN (runs over any access at the site)
    new List<Object>{'NFB-SDW-ESS','NovaWAN SD-WAN Essentials','Bundle',false,89.00,'Any',null,null,'SDWAN',10,false,
        'Connect every site over any internet link.',
        'Application-aware routing\nCloud management portal\nZero-touch provisioning',
        'Managed SD-WAN, Essentials licence, per site.'},
    new List<Object>{'NFB-SDW-ADV','NovaWAN SD-WAN Advanced','Bundle',false,149.00,'Any',null,null,'SDWAN',20,true,
        'SD-WAN with security and multi-link resilience.',
        'Everything in Essentials\nLink bonding and failover\nNext-gen firewall policies',
        'Managed SD-WAN, Advanced licence, per site.'},
    // ── Business Voice
    new List<Object>{'NFB-VOC-UC','NovaVoice UC','Bundle',false,49.00,'Any',null,null,'VOICE',10,true,
        'Cloud phone system with seats priced per user.',
        'Calling, video and messaging\nMobile and desktop apps\nPriced per seat',
        'Hosted unified communications; site platform fee plus seats.'},
    new List<Object>{'NFB-VOC-SIP','NovaVoice SIP Trunk','Bundle',false,39.00,'Any',null,null,'VOICE',20,false,
        'Connect your existing PBX, priced per channel.',
        'Works with existing PBXs\nBurst capacity on demand\nPriced per concurrent channel',
        'SIP trunking; site fee plus concurrent channels.'},
    // ── Components (sold only with other products)
    new List<Object>{'NFB-EQ-GW','Business Gateway','',false,0.00,null,null,null,null,10,false,'Included with Business Fiber.',null,'Business-grade router and firewall.'},
    new List<Object>{'NFB-EQ-AP','Managed Wi-Fi Access Point','',false,15.00,null,null,null,null,20,false,'Ceiling-mounted Wi-Fi 6E, managed by NovaFiber.',null,'Managed Wi-Fi access point, per unit.'},
    new List<Object>{'NFB-EQ-MRTR','Managed Edge Router','',false,0.00,null,null,null,null,30,false,'Included with Dedicated Internet.',null,'Carrier-managed edge router.'},
    new List<Object>{'NFB-EQ-SDWS','SD-WAN Edge Appliance (Small)','',false,35.00,null,null,null,null,40,false,'Up to 500 Mbps of WAN throughput.',null,'SD-WAN edge appliance for small sites.'},
    new List<Object>{'NFB-EQ-SDWL','SD-WAN Edge Appliance (Large)','',false,75.00,null,null,null,null,50,false,'Up to 5 Gbps of WAN throughput.',null,'SD-WAN edge appliance for large sites.'},
    new List<Object>{'NFB-EQ-PHONE','IP Desk Phone','',false,6.00,null,null,null,null,60,false,'Rented desk phone, one per seat as needed.',null,'IP desk phone rental, per unit.'},
    new List<Object>{'NFB-VOC-SEAT','UC Seat','',false,24.00,null,null,null,null,70,false,'One user: calling, video and messaging.',null,'Unified communications seat, per user.'},
    new List<Object>{'NFB-VOC-CHAN','SIP Channel','',false,18.00,null,null,null,null,80,false,'One concurrent call path.',null,'SIP trunk channel, per concurrent call.'},
    new List<Object>{'NFB-INS-STD','Standard Business Installation','',true,199.00,null,null,null,null,10,false,'Installed within 10 business days.',null,'Standard installation visit.'},
    new List<Object>{'NFB-INS-RUSH','Expedited Installation','',true,499.00,null,null,null,null,20,false,'Installed within 3 business days.',null,'Expedited installation visit.'},
    new List<Object>{'NFB-INS-DIA','Dedicated Circuit Build','',true,1500.00,null,null,null,null,30,false,'Site survey, fiber build and circuit turn-up.',null,'Dedicated circuit build and installation.'},
    new List<Object>{'NFB-INS-REMOTE','Remote Activation','',true,0.00,null,null,null,null,40,false,'Ships pre-configured; activated remotely.',null,'Zero-touch remote activation.'},
    new List<Object>{'NFB-INS-ONSITE','Onsite Installation','',true,299.00,null,null,null,null,50,false,'An engineer installs and tests on site.',null,'Onsite SD-WAN installation.'},
    new List<Object>{'NFB-ADD-IP8','Static IP Block /29','',false,25.00,null,null,null,null,10,false,'5 usable public IPv4 addresses.',null,'Static IPv4 block /29.'},
    new List<Object>{'NFB-ADD-IP16','Static IP Block /28','',false,45.00,null,null,null,null,20,false,'13 usable public IPv4 addresses.',null,'Static IPv4 block /28.'},
    new List<Object>{'NFB-ADD-BKP','5G Backup Connection','',false,59.00,null,null,null,null,30,false,'Automatic failover to 5G if the line goes down.',null,'5G wireless backup.'},
    new List<Object>{'NFB-ADD-FW','Managed Firewall','',false,79.00,null,null,null,null,40,false,'Next-gen firewall, monitored 24/7.',null,'Managed firewall service.'},
    new List<Object>{'NFB-ADD-DIV','Diverse Path','',false,350.00,null,null,null,null,50,false,'A second, physically separate fiber route.',null,'Route-diverse secondary path.'},
    new List<Object>{'NFB-ADD-DDOS','DDoS Protection','',false,199.00,null,null,null,null,60,false,'Always-on attack detection and scrubbing.',null,'DDoS mitigation service.'},
    new List<Object>{'NFB-ADD-AA','Auto Attendant','',false,20.00,null,null,null,null,70,false,'Menus and call routing for the main number.',null,'Auto attendant, per site.'},
    new List<Object>{'NFB-ADD-REC','Call Recording','',false,30.00,null,null,null,null,80,false,'Record and store calls for 90 days.',null,'Call recording, per site.'},
    new List<Object>{'NFB-ADD-DID','DID Number Block (100)','',false,15.00,null,null,null,null,90,false,'100 direct-dial numbers.',null,'Block of 100 DID numbers.'}
};

// ── Products (upsert by ProductCode)
Map<String, Product2> existing = new Map<String, Product2>();
for (Product2 p : [SELECT Id, ProductCode FROM Product2 WHERE ProductCode LIKE 'NFB-%']) existing.put(p.ProductCode, p);

Map<String, Product2> byCode = new Map<String, Product2>();
Map<String, Boolean> oneTimeByCode = new Map<String, Boolean>();
Map<String, Decimal> priceByCode = new Map<String, Decimal>();
Map<String, String> catByCode = new Map<String, String>();
for (List<Object> d : defs) {
    String code = (String) d[0];
    Product2 p = existing.containsKey(code) ? existing.get(code) : new Product2(ProductCode = code);
    p.Name = (String) d[1];
    p.Type = String.isBlank((String) d[2]) ? null : (String) d[2];
    p.ConfigureDuringSale = p.Type == 'Bundle' ? 'Allowed' : 'NotAllowed';
    p.IsActive = true;
    p.IsAssetizable = true;
    p.IsSoldOnlyWithOtherProds = (d[8] == null);
    p.NF_AccessTechnology__c = (String) d[5];
    p.NF_DownloadMbps__c = (Integer) d[6];
    p.NF_UploadMbps__c = (Integer) d[7];
    p.NF_DisplayOrder__c = (Integer) d[9];
    p.NF_IsFeatured__c = (Boolean) d[10];
    p.NF_Tagline__c = (String) d[11];
    p.NF_Highlights__c = (String) d[12];
    p.Description = (String) d[13];
    p.Family = d[8] == null ? 'NovaFiber Business Component' : 'NovaFiber Business';
    if (!taxPolicies.isEmpty()) p.TaxPolicyId = taxPolicies[0].Id;
    if (!billingPolicies.isEmpty()) p.BillingPolicyId = billingPolicies[0].Id;
    byCode.put(code, p);
    oneTimeByCode.put(code, (Boolean) d[3]);
    priceByCode.put(code, (Decimal) d[4]);
    catByCode.put(code, (String) d[8]);
}
upsert byCode.values();

// ── Selling model options
Set<Id> pids = new Set<Id>();
for (Product2 p : byCode.values()) pids.add(p.Id);
Set<Id> hasPsmo = new Set<Id>();
for (ProductSellingModelOption o : [SELECT Product2Id FROM ProductSellingModelOption WHERE Product2Id IN :pids]) hasPsmo.add(o.Product2Id);
List<ProductSellingModelOption> psmos = new List<ProductSellingModelOption>();
for (String code : byCode.keySet()) {
    Product2 p = byCode.get(code);
    if (hasPsmo.contains(p.Id)) continue;
    Boolean ot = oneTimeByCode.get(code);
    psmos.add(new ProductSellingModelOption(Product2Id = p.Id, ProductSellingModelId = ot ? psmOneTime : psmMonthly,
        ProrationPolicyId = ot ? null : proration, IsDefault = true));
}
insert psmos;

// ── Standard price book entries
Map<Id, PricebookEntry> pbeByProduct = new Map<Id, PricebookEntry>();
for (PricebookEntry e : [SELECT Id, Product2Id FROM PricebookEntry WHERE Pricebook2Id = :stdPb AND Product2Id IN :pids]) pbeByProduct.put(e.Product2Id, e);
List<PricebookEntry> pbes = new List<PricebookEntry>();
for (String code : byCode.keySet()) {
    Product2 p = byCode.get(code);
    PricebookEntry e = pbeByProduct.get(p.Id);
    if (e == null) {
        e = new PricebookEntry(Pricebook2Id = stdPb, Product2Id = p.Id,
            ProductSellingModelId = oneTimeByCode.get(code) ? psmOneTime : psmMonthly);
    }
    e.UnitPrice = priceByCode.get(code);
    e.IsActive = true;
    pbes.add(e);
}
upsert pbes;

// ── Catalog + categories
List<ProductCatalog> cats = [SELECT Id FROM ProductCatalog WHERE Code = 'NF_BIZ' LIMIT 1];
ProductCatalog catalog = cats.isEmpty() ? new ProductCatalog(Code = 'NF_BIZ') : cats[0];
catalog.Name = 'NovaFiber Business';
catalog.CatalogType = 'Sales';
catalog.Description = 'Business (B2B) offers sold by agents through multi-site quoting, priced per site state.';
catalog.EffectiveStartDate = DateTime.newInstance(2026, 1, 1);
upsert catalog;

Map<String, String> catNames = new Map<String, String>{ 'FIBER' => 'Business Fiber', 'DIA' => 'Dedicated Internet',
    'SDWAN' => 'SD-WAN', 'VOICE' => 'Business Voice' };
Map<String, Integer> catSort = new Map<String, Integer>{ 'FIBER' => 10, 'DIA' => 20, 'SDWAN' => 30, 'VOICE' => 40 };
Map<String, ProductCategory> catByKey = new Map<String, ProductCategory>();
for (ProductCategory c : [SELECT Id, Code FROM ProductCategory WHERE CatalogId = :catalog.Id]) catByKey.put(c.Code, c);
for (String key : catNames.keySet()) {
    String ccode = 'NFB_CAT_' + key;
    ProductCategory c = catByKey.containsKey(ccode) ? catByKey.get(ccode) : new ProductCategory(CatalogId = catalog.Id, Code = ccode);
    c.Name = catNames.get(key);
    c.SortOrder = catSort.get(key);
    c.IsNavigational = true;
    catByKey.put(ccode, c);
}
upsert catByKey.values();

delete [SELECT Id FROM ProductCategoryProduct WHERE ProductId IN :pids AND ProductCategory.CatalogId = :catalog.Id];
List<ProductCategoryProduct> pcps = new List<ProductCategoryProduct>();
for (String code : byCode.keySet()) {
    String key = catByCode.get(code);
    if (key == null) continue;
    pcps.add(new ProductCategoryProduct(ProductId = byCode.get(code).Id, ProductCategoryId = catByKey.get('NFB_CAT_' + key).Id));
}
insert pcps;

// ── Bundle structure: rebuild groups + components for NFB bundles
Set<Id> bundleIds = new Set<Id>();
for (Product2 p : byCode.values()) if (p.Type == 'Bundle') bundleIds.add(p.Id);
delete [SELECT Id FROM ProductRelatedComponent WHERE ParentProductId IN :bundleIds];
delete [SELECT Id FROM ProductComponentGroup WHERE ParentProductId IN :bundleIds];

// group spec: bundleCode, groupCode suffix, name, min, max, seq, [childCode, required, default, qty, minQty, maxQty, qtyEditable]...
List<List<Object>> groups = new List<List<Object>>();
for (String b : new List<String>{ 'NFB-FIB-500', 'NFB-FIB-1G', 'NFB-FIB-2G' }) {
    groups.add(new List<Object>{ b, 'EQUIP', 'Equipment', 1, 2, 10, new List<Object>{
        new List<Object>{ 'NFB-EQ-GW', true, true, 1, 1, 1, false },
        new List<Object>{ 'NFB-EQ-AP', false, false, 2, 1, 20, true } } });
    groups.add(new List<Object>{ b, 'INSTALL', 'Installation', 1, 1, 20, new List<Object>{
        new List<Object>{ 'NFB-INS-STD', false, true, 1, 1, 1, false },
        new List<Object>{ 'NFB-INS-RUSH', false, false, 1, 1, 1, false } } });
    groups.add(new List<Object>{ b, 'ADDONS', 'Add-ons', 0, 3, 30, new List<Object>{
        new List<Object>{ 'NFB-ADD-IP8', false, false, 1, 1, 1, false },
        new List<Object>{ 'NFB-ADD-IP16', false, false, 1, 1, 1, false },
        new List<Object>{ 'NFB-ADD-BKP', false, false, 1, 1, 1, false },
        new List<Object>{ 'NFB-ADD-FW', false, false, 1, 1, 1, false } } });
}
for (String b : new List<String>{ 'NFB-DIA-100', 'NFB-DIA-1G', 'NFB-DIA-10G' }) {
    groups.add(new List<Object>{ b, 'EQUIP', 'Equipment', 1, 1, 10, new List<Object>{
        new List<Object>{ 'NFB-EQ-MRTR', true, true, 1, 1, 1, false } } });
    groups.add(new List<Object>{ b, 'INSTALL', 'Installation', 1, 1, 20, new List<Object>{
        new List<Object>{ 'NFB-INS-DIA', true, true, 1, 1, 1, false } } });
    groups.add(new List<Object>{ b, 'IP', 'IP Addresses', 1, 1, 30, new List<Object>{
        new List<Object>{ 'NFB-ADD-IP8', false, true, 1, 1, 1, false },
        new List<Object>{ 'NFB-ADD-IP16', false, false, 1, 1, 1, false } } });
    groups.add(new List<Object>{ b, 'RESILIENCE', 'Resilience & Security', 0, 3, 40, new List<Object>{
        new List<Object>{ 'NFB-ADD-DIV', false, false, 1, 1, 1, false },
        new List<Object>{ 'NFB-ADD-DDOS', false, false, 1, 1, 1, false },
        new List<Object>{ 'NFB-ADD-BKP', false, false, 1, 1, 1, false } } });
}
for (String b : new List<String>{ 'NFB-SDW-ESS', 'NFB-SDW-ADV' }) {
    groups.add(new List<Object>{ b, 'EDGE', 'Edge Appliance', 1, 1, 10, new List<Object>{
        new List<Object>{ 'NFB-EQ-SDWS', false, true, 1, 1, 1, false },
        new List<Object>{ 'NFB-EQ-SDWL', false, false, 1, 1, 1, false } } });
    groups.add(new List<Object>{ b, 'INSTALL', 'Installation', 1, 1, 20, new List<Object>{
        new List<Object>{ 'NFB-INS-REMOTE', false, true, 1, 1, 1, false },
        new List<Object>{ 'NFB-INS-ONSITE', false, false, 1, 1, 1, false } } });
    groups.add(new List<Object>{ b, 'ADDONS', 'Add-ons', 0, 2, 30, new List<Object>{
        new List<Object>{ 'NFB-ADD-FW', false, false, 1, 1, 1, false },
        new List<Object>{ 'NFB-ADD-BKP', false, false, 1, 1, 1, false } } });
}
groups.add(new List<Object>{ 'NFB-VOC-UC', 'SEATS', 'Seats', 1, 1, 10, new List<Object>{
    new List<Object>{ 'NFB-VOC-SEAT', true, true, 10, 1, 250, true } } });
groups.add(new List<Object>{ 'NFB-VOC-UC', 'DEVICES', 'Devices', 0, 1, 20, new List<Object>{
    new List<Object>{ 'NFB-EQ-PHONE', false, false, 10, 1, 250, true } } });
groups.add(new List<Object>{ 'NFB-VOC-UC', 'ADDONS', 'Add-ons', 0, 3, 30, new List<Object>{
    new List<Object>{ 'NFB-ADD-AA', false, false, 1, 1, 1, false },
    new List<Object>{ 'NFB-ADD-REC', false, false, 1, 1, 1, false },
    new List<Object>{ 'NFB-ADD-DID', false, false, 1, 1, 10, true } } });
groups.add(new List<Object>{ 'NFB-VOC-SIP', 'CHANNELS', 'Channels', 1, 1, 10, new List<Object>{
    new List<Object>{ 'NFB-VOC-CHAN', true, true, 10, 2, 100, true } } });
groups.add(new List<Object>{ 'NFB-VOC-SIP', 'ADDONS', 'Add-ons', 0, 1, 20, new List<Object>{
    new List<Object>{ 'NFB-ADD-DID', false, false, 1, 1, 10, true } } });

List<ProductComponentGroup> pcgs = new List<ProductComponentGroup>();
for (List<Object> g : groups) {
    pcgs.add(new ProductComponentGroup(ParentProductId = byCode.get((String) g[0]).Id, Code = (String) g[0] + '-' + (String) g[1],
        Name = (String) g[2], MinBundleComponents = (Integer) g[3], MaxBundleComponents = (Integer) g[4], Sequence = (Integer) g[5]));
}
insert pcgs;

List<ProductRelatedComponent> prcs = new List<ProductRelatedComponent>();
for (Integer i = 0; i < groups.size(); i++) {
    List<Object> g = groups[i];
    Integer seq = 10;
    for (Object co : (List<Object>) g[6]) {
        List<Object> c = (List<Object>) co;
        Boolean qtyEditable = (Boolean) c[6];
        prcs.add(new ProductRelatedComponent(
            ParentProductId = byCode.get((String) g[0]).Id,
            ChildProductId = byCode.get((String) c[0]).Id,
            ProductComponentGroupId = pcgs[i].Id,
            ProductRelationshipTypeId = bundleRel,
            IsComponentRequired = (Boolean) c[1],
            IsDefaultComponent = (Boolean) c[2],
            Quantity = (Integer) c[3],
            // min/max may only be set on quantity-editable components
            MinQuantity = qtyEditable ? (Integer) c[4] : null,
            MaxQuantity = qtyEditable ? (Integer) c[5] : null,
            IsQuantityEditable = qtyEditable,
            DoesBundlePriceIncludeChild = false,
            QuoteVisibility = 'Always',
            Sequence = seq));
        seq += 10;
    }
}
insert prcs;

// ── Qualification: technology at the address + minimum speed (same rule shape as the residential plans)
List<List<Object>> rules = new List<List<Object>>{
    new List<Object>{ 'NFB-FIB-500', 'Fiber', 500 },
    new List<Object>{ 'NFB-FIB-1G', 'Fiber', 1000 },
    new List<Object>{ 'NFB-FIB-2G', 'Fiber', 2000 },
    new List<Object>{ 'NFB-DIA-100', 'Fiber', 0 },     // dedicated circuits are built to the site
    new List<Object>{ 'NFB-DIA-1G', 'Fiber', 0 },
    new List<Object>{ 'NFB-DIA-10G', 'Fiber', 1000 }   // only where high-capacity fiber reaches
};
for (String overTheTop : new List<String>{ 'NFB-SDW-ESS', 'NFB-SDW-ADV', 'NFB-VOC-UC', 'NFB-VOC-SIP' }) {
    for (String tech : new List<String>{ 'Fiber', 'Copper', '5G FWA' }) rules.add(new List<Object>{ overTheTop, tech, 0 });
}
delete [SELECT Id FROM ProductQualification WHERE Product.ProductCode LIKE 'NFB-%'];
List<ProductQualification> pqs = new List<ProductQualification>();
for (List<Object> r : rules) {
    pqs.add(new ProductQualification(ProductId = byCode.get((String) r[0]).Id, NF_AccessTechnology__c = (String) r[1],
        NF_MinDownloadMbps__c = (Integer) r[2], EffectiveFromDate = Date.newInstance(2026, 1, 1)));
}
insert pqs;

System.debug('NF_BIZ_SEED products=' + byCode.size() + ' psmo=' + psmos.size() + ' pbe=' + pbes.size()
    + ' catalog=' + catalog.Id + ' categories=' + catByKey.size() + ' pcp=' + pcps.size()
    + ' groups=' + pcgs.size() + ' components=' + prcs.size() + ' rules=' + pqs.size());
