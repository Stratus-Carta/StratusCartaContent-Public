// NovaFiber Residential catalog seed — idempotent.
// Creates products (NFR-*), selling model options, standard price book entries,
// the "NovaFiber Residential" catalog + categories, and bundle groups/components.
// Re-running updates products/prices and rebuilds groups/components for NFR bundles.

Id stdPb = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
Id psmMonthly = [SELECT Id FROM ProductSellingModel WHERE Name = 'Evergreen - Monthly' LIMIT 1].Id;
Id psmOneTime = [SELECT Id FROM ProductSellingModel WHERE Name = 'One-Time' LIMIT 1].Id;
Id proration  = [SELECT Id FROM ProrationPolicy WHERE Name = 'Default Proration Policy' LIMIT 1].Id;
Id bundleRel  = [SELECT Id FROM ProductRelationshipType WHERE MainProductRoleCat = 'Bundle' AND AssociatedProductRoleCat = 'BundleComponent' LIMIT 1].Id;

// code, name, type(Bundle|''), oneTime?, price, tech, down, up, category, order, featured, tagline, highlights, description
List<List<Object>> defs = new List<List<Object>>{
    // ── Internet plans (bundles)
    new List<Object>{'NFR-INT-300','NovaFiber 300','Bundle',false,49.99,'Fiber',300,300,'FIBER',10,false,
        'Fast, reliable fiber for everyday streaming and work.',
        'Symmetrical 300 Mbps upload & download\nWi-Fi 6 router included\nNo data caps, no annual contract',
        'Pure fiber internet, 300/300 Mbps.'},
    new List<Object>{'NFR-INT-1G','NovaFiber 1 Gig','Bundle',false,69.99,'Fiber',1000,1000,'FIBER',20,true,
        'Our most popular plan for busy, connected homes.',
        'Symmetrical 1 Gbps upload & download\nWi-Fi 6 router included\nPerfect for 4K streaming & gaming',
        'Pure fiber internet, 1000/1000 Mbps.'},
    new List<Object>{'NFR-INT-2G','NovaFiber 2 Gig','Bundle',false,89.99,'Fiber',2000,2000,'FIBER',30,false,
        'Multi-gig speeds for power users and home offices.',
        'Symmetrical 2 Gbps upload & download\nWi-Fi 6 router included\nPriority support line',
        'Pure fiber internet, 2000/2000 Mbps.'},
    new List<Object>{'NFR-INT-5G','NovaAir 5G Home','Bundle',false,45.00,'5G FWA',250,30,'FWA',40,false,
        'Wireless home internet where fiber has not reached yet.',
        'Up to 250 Mbps download\nOutdoor 5G receiver included\nEasy self-install in minutes',
        '5G fixed wireless access home internet.'},
    new List<Object>{'NFR-INT-DSL50','NovaDSL 50','Bundle',false,34.99,'Copper',50,10,'COPPER',50,false,
        'Dependable broadband over your existing phone line.',
        'Up to 50 Mbps download\nVDSL2 modem router included\nNo technician needed',
        'Copper (VDSL2) broadband, 50/10 Mbps.'},
    new List<Object>{'NFR-INT-DSL100','NovaDSL 100','Bundle',false,44.99,'Copper',100,20,'COPPER',60,false,
        'Our fastest copper plan for streaming households.',
        'Up to 100 Mbps download\nVDSL2 modem router included\nUpgrade to fiber when it arrives',
        'Copper (VDSL2) broadband, 100/20 Mbps.'},
    // ── TV plans (bundles)
    new List<Object>{'NFR-TV-ESS','NovaTV Essentials','Bundle',false,25.00,'Fiber',null,null,'TV',10,false,
        '80+ live channels including local news and sports.',
        '80+ live channels\nCloud DVR (50 hours)\nStream on 2 screens at once',
        'IPTV delivered over the NovaFiber network.'},
    new List<Object>{'NFR-TV-PRM','NovaTV Premium','Bundle',false,45.00,'Fiber',null,null,'TV',20,true,
        '160+ channels, unlimited DVR and 4K content.',
        '160+ live channels incl. 4K\nUnlimited cloud DVR\nStream on 5 screens at once',
        'Premium IPTV delivered over the NovaFiber network.'},
    // ── Mobile plans (simple)
    new List<Object>{'NFR-MOB-ESS','NovaMobile Essentials','',false,30.00,'Any',null,null,'MOBILE',10,false,
        '15 GB of 5G data with unlimited talk & text.',
        '15 GB 5G data\nUnlimited talk & text\nWi-Fi calling',
        'Mobile plan, 15 GB.'},
    new List<Object>{'NFR-MOB-UNL','NovaMobile Unlimited','',false,50.00,'Any',null,null,'MOBILE',20,true,
        'Unlimited 5G data, hotspot and international texting.',
        'Unlimited 5G data\n40 GB hotspot\nInternational texting',
        'Mobile plan, unlimited data.'},
    // ── Components (sold only with other products)
    new List<Object>{'NFR-EQ-RTR','Wi-Fi 6 Router','',false,0.00,null,null,null,null,10,false,'Included with every fiber plan.',null,'Wi-Fi 6 gateway router.'},
    new List<Object>{'NFR-EQ-MESH','Wi-Fi Mesh Extender','',false,5.00,null,null,null,null,20,false,'Extend coverage to every room.',null,'Wi-Fi 6 mesh extender.'},
    new List<Object>{'NFR-EQ-5GCPE','5G Outdoor Receiver','',false,0.00,null,null,null,null,30,false,'Included with NovaAir 5G Home.',null,'5G FWA outdoor CPE.'},
    new List<Object>{'NFR-EQ-DSLMODEM','VDSL2 Modem Router','',false,0.00,null,null,null,null,35,false,'Included with every copper plan.',null,'VDSL2 modem with built-in Wi-Fi.'},
    new List<Object>{'NFR-EQ-STB','4K Set-Top Box','',false,7.00,null,null,null,null,40,false,'One per TV.',null,'4K IPTV set-top box.'},
    new List<Object>{'NFR-INS-PRO','Professional Installation','',true,99.00,null,null,null,null,10,false,'A certified technician sets everything up.',null,'Technician installation visit.'},
    new List<Object>{'NFR-INS-SELF','Self-Install Kit','',true,0.00,null,null,null,null,20,false,'Ships in 2 business days.',null,'Self-install kit shipped to the service address.'},
    new List<Object>{'NFR-ADD-SIP','Static IP Address','',false,10.00,null,null,null,null,10,false,'A fixed public IPv4 address.',null,'Static IPv4 address.'},
    new List<Object>{'NFR-ADD-SEC','NovaShield Security','',false,6.00,null,null,null,null,20,false,'Network-level malware and phishing protection.',null,'Network security add-on.'},
    new List<Object>{'NFR-ADD-CARE','Tech Care Plus','',false,8.00,null,null,null,null,30,false,'24/7 premium tech support and device help.',null,'Premium support add-on.'},
    new List<Object>{'NFR-TV-SPORT','Sports Pack','',false,15.00,null,null,null,null,10,false,'Regional and premium sports networks.',null,'TV channel pack.'},
    new List<Object>{'NFR-TV-MOVIE','Movies Pack','',false,12.00,null,null,null,null,20,false,'Premium movie channels on demand.',null,'TV channel pack.'}
};

// ── Products (upsert by ProductCode)
Map<String, Product2> existing = new Map<String, Product2>();
for (Product2 p : [SELECT Id, ProductCode FROM Product2 WHERE ProductCode LIKE 'NFR-%']) existing.put(p.ProductCode, p);

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
    p.Family = d[8] == null ? 'NovaFiber Component' : 'NovaFiber ' + ((String) d[8]).toLowerCase().capitalize();
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
    psmos.add(new ProductSellingModelOption(
        Product2Id = p.Id,
        ProductSellingModelId = ot ? psmOneTime : psmMonthly,
        ProrationPolicyId = ot ? null : proration,
        IsDefault = true));
}
insert psmos;

// ── Standard price book entries (one per product/selling model)
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
List<ProductCatalog> cats = [SELECT Id FROM ProductCatalog WHERE Code = 'NF_RESI' LIMIT 1];
ProductCatalog catalog = cats.isEmpty() ? new ProductCatalog(Code = 'NF_RESI') : cats[0];
catalog.Name = 'NovaFiber Residential';
catalog.CatalogType = 'Sales';
catalog.Description = 'Residential offers sold through the NovaFiber guided selling journey (self-service + agent).';
catalog.EffectiveStartDate = DateTime.newInstance(2026, 1, 1);
upsert catalog;

Map<String, String> catNames = new Map<String, String>{ 'FIBER' => 'Fiber Internet', 'COPPER' => 'Copper Internet', 'FWA' => '5G Home Internet', 'TV' => 'TV & Streaming', 'MOBILE' => 'Mobile' };
Map<String, Integer> catSort = new Map<String, Integer>{ 'FIBER' => 10, 'COPPER' => 20, 'FWA' => 30, 'TV' => 40, 'MOBILE' => 50 };
Map<String, ProductCategory> catByKey = new Map<String, ProductCategory>();
for (ProductCategory c : [SELECT Id, Code FROM ProductCategory WHERE CatalogId = :catalog.Id]) catByKey.put(c.Code, c);
for (String key : catNames.keySet()) {
    String ccode = 'NF_CAT_' + key;
    ProductCategory c = catByKey.containsKey(ccode) ? catByKey.get(ccode) : new ProductCategory(CatalogId = catalog.Id, Code = ccode);
    c.Name = catNames.get(key);
    c.SortOrder = catSort.get(key);
    c.IsNavigational = true;
    catByKey.put(ccode, c);
}
upsert catByKey.values();

// Retire categories that are no longer part of the design (e.g. the old combined 'Home Internet').
Set<String> keepCodes = new Set<String>();
for (String key : catNames.keySet()) keepCodes.add('NF_CAT_' + key);
List<ProductCategory> retired = [SELECT Id FROM ProductCategory WHERE CatalogId = :catalog.Id AND Code NOT IN :keepCodes];
delete [SELECT Id FROM ProductCategoryProduct WHERE ProductCategoryId IN :retired];
delete retired;
// Products move between categories: rebuild NFR category links.
delete [SELECT Id FROM ProductCategoryProduct WHERE ProductId IN :pids AND ProductCategory.CatalogId = :catalog.Id];

Set<String> linked = new Set<String>();
for (ProductCategoryProduct pcp : [SELECT ProductId, ProductCategoryId FROM ProductCategoryProduct WHERE ProductId IN :pids]) linked.add(pcp.ProductId + '|' + pcp.ProductCategoryId);
List<ProductCategoryProduct> pcps = new List<ProductCategoryProduct>();
for (String code : byCode.keySet()) {
    String key = catByCode.get(code);
    if (key == null) continue;
    Id catId = catByKey.get('NF_CAT_' + key).Id;
    Id pid = byCode.get(code).Id;
    if (!linked.contains(pid + '|' + catId)) pcps.add(new ProductCategoryProduct(ProductId = pid, ProductCategoryId = catId));
}
insert pcps;

// ── Bundle structure: rebuild groups + components for NFR bundles
Set<Id> bundleIds = new Set<Id>();
for (Product2 p : byCode.values()) if (p.Type == 'Bundle') bundleIds.add(p.Id);
delete [SELECT Id FROM ProductRelatedComponent WHERE ParentProductId IN :bundleIds];
delete [SELECT Id FROM ProductComponentGroup WHERE ParentProductId IN :bundleIds];

// group spec: bundleCode, groupCode suffix, name, min, max, seq, [childCode, required, default, qty, minQty, maxQty, qtyEditable]...
List<List<Object>> groups = new List<List<Object>>();
for (String b : new List<String>{ 'NFR-INT-300', 'NFR-INT-1G', 'NFR-INT-2G' }) {
    groups.add(new List<Object>{ b, 'EQUIP', 'Equipment', 1, 2, 10, new List<Object>{
        new List<Object>{ 'NFR-EQ-RTR', true, true, 1, 1, 1, false },
        new List<Object>{ 'NFR-EQ-MESH', false, false, 1, 1, 3, true } } });
    groups.add(new List<Object>{ b, 'INSTALL', 'Installation', 1, 1, 20, new List<Object>{
        new List<Object>{ 'NFR-INS-PRO', false, true, 1, 1, 1, false },
        new List<Object>{ 'NFR-INS-SELF', false, false, 1, 1, 1, false } } });
    groups.add(new List<Object>{ b, 'ADDONS', 'Add-ons', 0, 3, 30, new List<Object>{
        new List<Object>{ 'NFR-ADD-SIP', false, false, 1, 1, 1, false },
        new List<Object>{ 'NFR-ADD-SEC', false, false, 1, 1, 1, false },
        new List<Object>{ 'NFR-ADD-CARE', false, false, 1, 1, 1, false } } });
}
groups.add(new List<Object>{ 'NFR-INT-5G', 'EQUIP', 'Equipment', 1, 2, 10, new List<Object>{
    new List<Object>{ 'NFR-EQ-5GCPE', true, true, 1, 1, 1, false },
    new List<Object>{ 'NFR-EQ-MESH', false, false, 1, 1, 3, true } } });
groups.add(new List<Object>{ 'NFR-INT-5G', 'INSTALL', 'Installation', 1, 1, 20, new List<Object>{
    new List<Object>{ 'NFR-INS-SELF', false, true, 1, 1, 1, false },
    new List<Object>{ 'NFR-INS-PRO', false, false, 1, 1, 1, false } } });
groups.add(new List<Object>{ 'NFR-INT-5G', 'ADDONS', 'Add-ons', 0, 2, 30, new List<Object>{
    new List<Object>{ 'NFR-ADD-SEC', false, false, 1, 1, 1, false },
    new List<Object>{ 'NFR-ADD-CARE', false, false, 1, 1, 1, false } } });
for (String b : new List<String>{ 'NFR-INT-DSL50', 'NFR-INT-DSL100' }) {
    groups.add(new List<Object>{ b, 'EQUIP', 'Equipment', 1, 2, 10, new List<Object>{
        new List<Object>{ 'NFR-EQ-DSLMODEM', true, true, 1, 1, 1, false },
        new List<Object>{ 'NFR-EQ-MESH', false, false, 1, 1, 3, true } } });
    groups.add(new List<Object>{ b, 'INSTALL', 'Installation', 1, 1, 20, new List<Object>{
        new List<Object>{ 'NFR-INS-SELF', false, true, 1, 1, 1, false },
        new List<Object>{ 'NFR-INS-PRO', false, false, 1, 1, 1, false } } });
    groups.add(new List<Object>{ b, 'ADDONS', 'Add-ons', 0, 2, 30, new List<Object>{
        new List<Object>{ 'NFR-ADD-SEC', false, false, 1, 1, 1, false },
        new List<Object>{ 'NFR-ADD-CARE', false, false, 1, 1, 1, false } } });
}
for (String b : new List<String>{ 'NFR-TV-ESS', 'NFR-TV-PRM' }) {
    groups.add(new List<Object>{ b, 'EQUIP', 'Equipment', 1, 1, 10, new List<Object>{
        new List<Object>{ 'NFR-EQ-STB', true, true, 1, 1, 4, true } } });
    groups.add(new List<Object>{ b, 'PACKS', 'Channel Packs', 0, 2, 20, new List<Object>{
        new List<Object>{ 'NFR-TV-SPORT', false, false, 1, 1, 1, false },
        new List<Object>{ 'NFR-TV-MOVIE', false, false, 1, 1, 1, false } } });
}

List<ProductComponentGroup> pcgs = new List<ProductComponentGroup>();
for (List<Object> g : groups) {
    Product2 parent = byCode.get((String) g[0]);
    pcgs.add(new ProductComponentGroup(
        ParentProductId = parent.Id,
        Code = (String) g[0] + '-' + (String) g[1],
        Name = (String) g[2],
        MinBundleComponents = (Integer) g[3],
        MaxBundleComponents = (Integer) g[4],
        Sequence = (Integer) g[5]));
}
insert pcgs;

List<ProductRelatedComponent> prcs = new List<ProductRelatedComponent>();
for (Integer i = 0; i < groups.size(); i++) {
    List<Object> g = groups[i];
    Product2 parent = byCode.get((String) g[0]);
    Integer seq = 10;
    for (Object co : (List<Object>) g[6]) {
        List<Object> c = (List<Object>) co;
        String childCode = (String) c[0];
        Boolean qtyEditable = (Boolean) c[6];
        prcs.add(new ProductRelatedComponent(
            ParentProductId = parent.Id,
            ChildProductId = byCode.get(childCode).Id,
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

System.debug('NF_SEED products=' + byCode.size() + ' psmo=' + psmos.size() + ' pbe=' + pbes.size()
    + ' catalog=' + catalog.Id + ' categories=' + catByKey.size() + ' pcp=' + pcps.size()
    + ' groups=' + pcgs.size() + ' components=' + prcs.size());

