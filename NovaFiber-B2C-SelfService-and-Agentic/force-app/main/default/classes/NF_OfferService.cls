/**
 * NF_OfferService
 * Builds the offers for an address with Revenue Cloud Product Discovery, so eligibility,
 * prices and bundle structure all come from Revenue Cloud:
 *
 *   1. POST /connect/cpq/products       once per technology the address supports. The address
 *      technology and max speed go in as Context Service data (Account node: NF_AccessTechnology,
 *      NF_MaxDownloadMbps). The org qualification procedure (NF Serviceability Qualification)
 *      evaluates the ProductQualification rules and flags each product isQualified.
 *   2. POST /connect/cpq/products/bulk  for the qualified bundles: component groups, options
 *      and their prices.
 *
 * Catalogs: NF_RESI (residential site, guided flow, Nova) by default; NF_BIZ (business) for multi-site quoting.
 *
 * A product is offered when at least one technology qualifies it. Marketing copy (tagline,
 * highlights, speeds) is requested through Discovery additionalFields; only catalog/category
 * metadata (ids, codes, order) is read with SOQL.
 */
public inherited sharing class NF_OfferService {

    public static final String CATALOG_CODE = 'NF_RESI';
    public static final String BUSINESS_CATALOG_CODE = 'NF_BIZ';
    public static final String TECH_NONE = 'None';
    private static final String CODE_SELF_INSTALL = 'NFR-INS-SELF';
    private static final String PATH_PRODUCTS = '/connect/cpq/products';
    private static final String PATH_BULK = '/connect/cpq/products/bulk';
    private static final List<String> MARKETING_FIELDS = new List<String>{
        'NF_Tagline__c', 'NF_Highlights__c', 'NF_DownloadMbps__c', 'NF_UploadMbps__c',
        'NF_IsFeatured__c', 'NF_DisplayOrder__c'
    };


    public static List<NF_JourneyModels.OfferCategory> getOffers(NF_JourneyModels.ServiceabilityResult svc) {
        return getOffers(svc, true);
    }

    /** useCache=false always asks Revenue Cloud; in Realtime mode the cache is never read either. */
    public static List<NF_JourneyModels.OfferCategory> getOffers(NF_JourneyModels.ServiceabilityResult svc, Boolean useCache) {
        return getOffers(svc, useCache, CATALOG_CODE);
    }

    /** Offers from the given catalog (CATALOG_CODE or BUSINESS_CATALOG_CODE). */
    public static List<NF_JourneyModels.OfferCategory> getOffers(NF_JourneyModels.ServiceabilityResult svc, Boolean useCache,
                                                                 String catalogCode) {
        List<NF_JourneyModels.Technology> techs = new List<NF_JourneyModels.Technology>();
        if (svc != null && svc.technologies != null) techs.addAll(svc.technologies);
        // No home internet: still run qualification so "any technology" products (mobile) are offered.
        if (techs.isEmpty()) techs.add(tech(TECH_NONE, 0));

        String cacheKey = cacheKey(catalogCode, techs);
        if (useCache) {
            List<NF_JourneyModels.OfferCategory> cached = fromCache(cacheKey, 'Offers');
            if (cached != null) return cached;
        }
        List<NF_JourneyModels.OfferCategory> result = discoverOffers(catalogCode, techs);
        toCache(cacheKey, result);
        return result;
    }

    private static List<NF_JourneyModels.OfferCategory> discoverOffers(String catalogCode, List<NF_JourneyModels.Technology> techs) {
        CatalogInfo cat = catalog(catalogCode);

        Map<String, Map<String, Object>> qualified = new Map<String, Map<String, Object>>();
        Map<String, NF_JourneyModels.Technology> qualifiedVia = new Map<String, NF_JourneyModels.Technology>();
        Map<String, String> rejected = new Map<String, String>();
        Map<String, String> names = new Map<String, String>();
        for (NF_JourneyModels.Technology t : techs) {
            Map<String, Object> res = NF_RevCloudApi.post(PATH_PRODUCTS, discoveryRequest(cat, t),
                'Product Discovery · qualify for ' + t.technology + ' ≤ ' + t.maxDownloadMbps + ' Mbps');
            assertQualificationRan(res);
            for (Object o : asList(res.get('result'))) {
                Map<String, Object> p = asMap(o);
                String id = str(p, 'id');
                names.put(id, str(p, 'name'));
                if (isQualified(p)) {
                    if (!qualified.containsKey(id)) {
                        qualified.put(id, p);
                        qualifiedVia.put(id, t);
                    }
                } else if (!rejected.containsKey(id)) {
                    rejected.put(id, t.technology + ': ' + reason(p));
                }
            }
        }

        Map<String, Map<String, Object>> bundleDetails = loadBundleDetails(cat, qualified, qualifiedVia);
        List<NF_JourneyModels.OfferCategory> result = buildCategories(cat, qualified, qualifiedVia, bundleDetails);
        traceDecisions(names, qualified, qualifiedVia, rejected);
        return result;
    }

    /** Marketing preview of the whole catalog: Discovery with pricing, without qualification. */
    public static List<NF_JourneyModels.OfferCategory> getCatalogPreview() {
        String key = NF_JourneyCache.key('preview', CATALOG_CODE);
        List<NF_JourneyModels.OfferCategory> cached = fromCache(key, 'Catalog preview');
        if (cached != null) return cached;
        List<NF_JourneyModels.OfferCategory> preview = discoverPreview();
        toCache(key, preview);
        return preview;
    }

    private static List<NF_JourneyModels.OfferCategory> discoverPreview() {
        CatalogInfo cat = catalog(CATALOG_CODE);
        Map<String, Object> req = baseRequest(cat);
        req.put('enableQualification', false);
        Map<String, Object> res = NF_RevCloudApi.post(PATH_PRODUCTS, req, 'Product Discovery · catalog preview');
        Map<String, Map<String, Object>> all = new Map<String, Map<String, Object>>();
        for (Object o : asList(res.get('result'))) {
            Map<String, Object> p = asMap(o);
            all.put(str(p, 'id'), p);
        }
        return buildCategories(cat, all, new Map<String, NF_JourneyModels.Technology>(),
            new Map<String, Map<String, Object>>());
    }

    // ── Cache (NF_JourneyCache: read in Cached mode, refreshed in both modes) ──

    private static String cacheKey(String catalogCode, List<NF_JourneyModels.Technology> techs) {
        List<String> parts = new List<String>{ catalogCode };
        for (NF_JourneyModels.Technology t : techs) {
            parts.add(t.technology + '|' + t.maxDownloadMbps + '|' + t.installType);
        }
        parts.sort();
        return NF_JourneyCache.key('offers', String.join(parts, ';'));
    }

    /** Offers already read in this transaction (e.g. an agent action and the cart sync it runs): no second cache read. */
    private static Map<String, String> readThisCall = new Map<String, String>();

    private static List<NF_JourneyModels.OfferCategory> fromCache(String key, String what) {
        String hit = readThisCall.get(key);
        if (hit == null) {
            hit = NF_JourneyCache.read(key);
            if (hit == null) return null;
            NF_Trace.note('CACHE', what + ' from cache', 'Revenue Cloud Discovery result (TTL ' + NF_JourneyCache.TTL_CATALOG + 's)');
            readThisCall.put(key, hit);
        }
        return (List<NF_JourneyModels.OfferCategory>) JSON.deserialize(hit, List<NF_JourneyModels.OfferCategory>.class);
    }

    private static void toCache(String key, List<NF_JourneyModels.OfferCategory> offers) {
        String json = JSON.serialize(offers);
        NF_JourneyCache.put(key, json, NF_JourneyCache.TTL_CATALOG);
        readThisCall.put(key, json);
    }
    // ── Revenue Cloud requests ───────────────────────────────────────────────

    private static Map<String, Object> baseRequest(CatalogInfo cat) {
        return new Map<String, Object>{
            'catalogId' => cat.catalogId,
            'priceBookId' => cat.pricebookId,
            'enablePricing' => true,
            'additionalFields' => new Map<String, Object>{
                'Product2' => new Map<String, Object>{ 'fields' => MARKETING_FIELDS }
            }
        };
    }

    private static Map<String, Object> discoveryRequest(CatalogInfo cat, NF_JourneyModels.Technology t) {
        Map<String, Object> req = baseRequest(cat);
        req.put('enableQualification', true);
        req.put('additionalContextData', contextData(t));
        return req;
    }

    /** Address serviceability as Context Service data, read by the qualification procedure. */
    private static List<Object> contextData(NF_JourneyModels.Technology t) {
        return new List<Object>{ new Map<String, Object>{
            'nodeName' => 'Account',
            'nodeData' => new Map<String, Object>{
                'NF_AccessTechnology' => t.technology,
                'NF_MaxDownloadMbps' => t.maxDownloadMbps == null ? 0 : t.maxDownloadMbps
            }
        } };
    }

    private static Map<String, Map<String, Object>> loadBundleDetails(CatalogInfo cat,
            Map<String, Map<String, Object>> qualified, Map<String, NF_JourneyModels.Technology> via) {
        Map<String, Map<String, Object>> details = new Map<String, Map<String, Object>>();
        List<Object> productData = new List<Object>();
        NF_JourneyModels.Technology contextTech;
        for (String id : qualified.keySet()) {
            if (str(qualified.get(id), 'productType') != 'Bundle') continue;
            productData.add(new Map<String, Object>{ 'productId' => id });
            if (contextTech == null) contextTech = via.get(id);
        }
        if (productData.isEmpty()) return details;
        Map<String, Object> req = baseRequest(cat);
        req.put('enableQualification', true);
        req.put('productData', productData);
        req.put('additionalContextData', contextData(contextTech));
        Map<String, Object> res = NF_RevCloudApi.post(PATH_BULK, req,
            'Product details · ' + productData.size() + ' bundle(s): groups, options, prices');
        for (Object o : asList(res.get('result'))) {
            Map<String, Object> p = asMap(o);
            details.put(str(p, 'id'), p);
        }
        return details;
    }

    /** Qualification that silently fails would offer everything; fail loudly instead. */
    private static void assertQualificationRan(Map<String, Object> res) {
        Map<String, Object> status = asMap(res.get('apiStatus'));
        String code = str(status, 'statusCode');
        if (code != null && code.contains('Failed')) {
            List<String> msgs = new List<String>();
            for (Object m : asList(status.get('messages'))) msgs.add(str(asMap(m), 'message'));
            System.debug(LoggingLevel.ERROR, 'NF discovery ' + code + ': ' + String.join(msgs, ' / '));
            throw new NF_JourneyModels.JourneyException(
                'We could not check which plans are available at this address. Please try again in a moment.');
        }
    }

    // ── Mapping ──────────────────────────────────────────────────────────────

    private static List<NF_JourneyModels.OfferCategory> buildCategories(CatalogInfo cat,
            Map<String, Map<String, Object>> products, Map<String, NF_JourneyModels.Technology> via,
            Map<String, Map<String, Object>> details) {
        Map<String, NF_JourneyModels.OfferCategory> byCategory = new Map<String, NF_JourneyModels.OfferCategory>();
        for (ProductCategory c : cat.categories) {
            NF_JourneyModels.OfferCategory oc = new NF_JourneyModels.OfferCategory();
            oc.key = c.Code;
            oc.label = c.Name;
            oc.offers = new List<NF_JourneyModels.Offer>();
            byCategory.put(c.Id, oc);
        }
        List<OfferSort> sorted = new List<OfferSort>();
        for (String id : products.keySet()) {
            Map<String, Object> p = products.get(id);
            NF_JourneyModels.OfferCategory oc = categoryOf(p, byCategory);
            if (oc == null) continue;
            NF_JourneyModels.Offer o = toOffer(p, oc.key, via.get(id), details.get(id));
            if (o.price == null) continue;   // not sellable without a price
            sorted.add(new OfferSort(oc, o, dec(asMap(p.get('additionalFields')), 'NF_DisplayOrder__c')));
        }
        sorted.sort();
        for (OfferSort s : sorted) s.category.offers.add(s.offer);

        List<NF_JourneyModels.OfferCategory> result = new List<NF_JourneyModels.OfferCategory>();
        for (ProductCategory c : cat.categories) {
            NF_JourneyModels.OfferCategory oc = byCategory.get(c.Id);
            if (!oc.offers.isEmpty()) result.add(oc);
        }
        return result;
    }

    private static NF_JourneyModels.OfferCategory categoryOf(Map<String, Object> p,
            Map<String, NF_JourneyModels.OfferCategory> byCategory) {
        for (Object c : asList(p.get('categories'))) {
            NF_JourneyModels.OfferCategory oc = byCategory.get(str(asMap(c), 'id'));
            if (oc != null) return oc;
        }
        return null;
    }

    private static NF_JourneyModels.Offer toOffer(Map<String, Object> p, String categoryKey,
            NF_JourneyModels.Technology tech, Map<String, Object> detail) {
        Map<String, Object> extra = asMap(p.get('additionalFields'));
        NF_JourneyModels.Offer o = new NF_JourneyModels.Offer();
        o.productId = str(p, 'id');
        o.productCode = str(p, 'productCode');
        o.name = str(p, 'name');
        o.tagline = unescape(str(extra, 'NF_Tagline__c'));
        String highlights = unescape(str(extra, 'NF_Highlights__c'));
        o.highlights = String.isBlank(highlights) ? new List<String>() : highlights.split('\n');
        o.categoryKey = categoryKey;
        Map<String, Object> price = defaultPrice(p);
        o.price = dec(price, 'price');
        o.chargeType = chargeType(price);
        o.priceBookEntryId = str(price, 'priceBookEntryId');
        o.productSellingModelId = str(asMap(price.get('pricingModel')), 'id');
        o.sellingModelType = str(asMap(price.get('pricingModel')), 'pricingModelType');
        o.isBundle = str(p, 'productType') == 'Bundle';
        o.isFeatured = extra.get('NF_IsFeatured__c') == true;
        o.downloadMbps = intOrNull(dec(extra, 'NF_DownloadMbps__c'));
        o.uploadMbps = intOrNull(dec(extra, 'NF_UploadMbps__c'));
        o.technology = tech == null || tech.technology == TECH_NONE ? null : tech.technology;
        o.groups = new List<NF_JourneyModels.OptionGroup>();
        if (detail != null) {
            Boolean newBuild = tech != null && tech.installType == 'New Build';
            for (Object g : asList(detail.get('productComponentGroups'))) {
                NF_JourneyModels.OptionGroup og = toGroup(asMap(g), newBuild);
                if (!og.options.isEmpty()) o.groups.add(og);
            }
        }
        return o;
    }

    private static NF_JourneyModels.OptionGroup toGroup(Map<String, Object> g, Boolean newBuild) {
        NF_JourneyModels.OptionGroup og = new NF_JourneyModels.OptionGroup();
        og.groupId = str(g, 'id');
        og.name = str(g, 'name');
        og.minOptions = intOrNull(dec(g, 'minBundleComponents'));
        if (og.minOptions == null) og.minOptions = 0;
        og.maxOptions = intOrNull(dec(g, 'maxBundleComponents'));
        og.options = new List<NF_JourneyModels.Option>();
        for (Object c : asList(g.get('components'))) {
            Map<String, Object> comp = asMap(c);
            Map<String, Object> rel = asMap(comp.get('productRelatedComponent'));
            // A new-build fiber drop needs a technician: hide self-install.
            if (newBuild && str(comp, 'productCode') == CODE_SELF_INSTALL) continue;
            Map<String, Object> qc = asMap(comp.get('qualificationContext'));
            if (qc.get('isQualified') == false) continue;
            Map<String, Object> price = defaultPrice(comp);
            if (price.isEmpty()) continue;
            NF_JourneyModels.Option op = new NF_JourneyModels.Option();
            op.componentId = str(rel, 'id');
            op.productId = str(comp, 'id');
            op.name = str(comp, 'name');
            op.tagline = unescape(str(asMap(comp.get('additionalFields')), 'NF_Tagline__c'));
            op.price = dec(price, 'price');
            op.chargeType = chargeType(price);
            op.priceBookEntryId = str(price, 'priceBookEntryId');
            op.productSellingModelId = str(asMap(price.get('pricingModel')), 'id');
            op.sellingModelType = str(asMap(price.get('pricingModel')), 'pricingModelType');
            op.relationshipTypeId = str(rel, 'productRelationshipTypeId');
            op.isRequired = rel.get('isComponentRequired') == true;
            op.isDefault = rel.get('isDefaultComponent') == true;
            op.isQuantityEditable = rel.get('isQuantityEditable') == true;
            Integer qty = intOrNull(dec(rel, 'quantity'));
            op.defaultQuantity = qty == null ? 1 : qty;
            Integer minQ = intOrNull(dec(rel, 'minQuantity'));
            Integer maxQ = intOrNull(dec(rel, 'maxQuantity'));
            op.minQuantity = minQ == null ? op.defaultQuantity : minQ;
            op.maxQuantity = maxQ == null ? op.defaultQuantity : maxQ;
            og.options.add(op);
        }
        // If filtering removed the default of a mandatory group, default the first option.
        Boolean hasDefault = false;
        for (NF_JourneyModels.Option op : og.options) hasDefault |= op.isDefault;
        if (!hasDefault && og.minOptions > 0 && !og.options.isEmpty()) og.options[0].isDefault = true;
        return og;
    }

    private static Map<String, Object> defaultPrice(Map<String, Object> p) {
        Map<String, Object> first;
        for (Object o : asList(p.get('prices'))) {
            Map<String, Object> pr = asMap(o);
            if (first == null) first = pr;
            if (pr.get('isDefault') == true) return pr;
        }
        return first == null ? new Map<String, Object>() : first;
    }

    private static String chargeType(Map<String, Object> price) {
        return str(asMap(price.get('pricingModel')), 'pricingModelType') == 'OneTime' ? 'One-Time' : 'Monthly';
    }

    private static Boolean isQualified(Map<String, Object> p) {
        return asMap(p.get('qualificationContext')).get('isQualified') != false;
    }

    private static String reason(Map<String, Object> p) {
        String r = str(asMap(p.get('qualificationContext')), 'reason');
        return String.isBlank(r) ? 'not qualified' : r.normalizeSpace().left(240);
    }

    private static void traceDecisions(Map<String, String> names, Map<String, Map<String, Object>> qualified,
            Map<String, NF_JourneyModels.Technology> via, Map<String, String> rejected) {
        List<Map<String, String>> decisions = new List<Map<String, String>>();
        for (String id : names.keySet()) {
            String outcome = qualified.containsKey(id)
                ? 'offered via ' + via.get(id).technology
                : 'excluded · ' + rejected.get(id);
            decisions.add(new Map<String, String>{ 'product' => names.get(id), 'result' => outcome });
        }
        NF_Trace.Entry rule = NF_Trace.note('RULE', 'Revenue Cloud qualification',
            qualified.size() + ' of ' + names.size() + ' products qualified (procedure NF Serviceability Qualification)');
        if (rule != null) rule.responseJson = NF_Trace.toJson(decisions);
    }

    private class OfferSort implements Comparable {
        NF_JourneyModels.OfferCategory category;
        NF_JourneyModels.Offer offer;
        Decimal order;
        OfferSort(NF_JourneyModels.OfferCategory category, NF_JourneyModels.Offer offer, Decimal order) {
            this.category = category;
            this.offer = offer;
            this.order = order == null ? 9999 : order;
        }
        public Integer compareTo(Object other) {
            OfferSort o = (OfferSort) other;
            if (order != o.order) return order < o.order ? -1 : 1;
            return offer.name.compareTo(o.offer.name);
        }
    }

    // ── Catalog metadata ─────────────────────────────────────────────────────

    private class CatalogInfo {
        Id catalogId;
        Id pricebookId;
        List<ProductCategory> categories;
    }

    private static CatalogInfo catalog(String catalogCode) {
        List<ProductCatalog> catalogs = [SELECT Id FROM ProductCatalog WHERE Code = :catalogCode LIMIT 1];
        if (catalogs.isEmpty()) {
            throw new NF_JourneyModels.JourneyException('The NovaFiber catalog is not available right now.');
        }
        CatalogInfo info = new CatalogInfo();
        info.catalogId = catalogs[0].Id;
        info.pricebookId = standardPricebookId();
        info.categories = [
            SELECT Id, Name, Code FROM ProductCategory
            WHERE CatalogId = :info.catalogId AND IsNavigational = true
            ORDER BY SortOrder ASC NULLS LAST, Name ASC
        ];
        return info;
    }

    private static Id standardPricebookId() {
        if (Test.isRunningTest()) return Test.getStandardPricebookId();
        List<Pricebook2> pbs = [SELECT Id FROM Pricebook2 WHERE IsStandard = true AND IsActive = true LIMIT 1];
        if (pbs.isEmpty()) throw new NF_JourneyModels.JourneyException('No active price book is configured.');
        return pbs[0].Id;
    }

    // ── JSON helpers ─────────────────────────────────────────────────────────

    private static NF_JourneyModels.Technology tech(String name, Integer maxDown) {
        NF_JourneyModels.Technology t = new NF_JourneyModels.Technology();
        t.technology = name;
        t.maxDownloadMbps = maxDown;
        return t;
    }

    private static Map<String, Object> asMap(Object o) {
        return o instanceof Map<String, Object> ? (Map<String, Object>) o : new Map<String, Object>();
    }

    private static List<Object> asList(Object o) {
        return o instanceof List<Object> ? (List<Object>) o : new List<Object>();
    }

    private static String str(Map<String, Object> m, String key) {
        Object v = m == null ? null : m.get(key);
        return v == null ? null : String.valueOf(v);
    }

    private static Decimal dec(Map<String, Object> m, String key) {
        Object v = m == null ? null : m.get(key);
        if (v == null) return null;
        if (v instanceof Decimal) return (Decimal) v;
        if (v instanceof Integer) return (Integer) v;
        if (v instanceof Long) return (Long) v;
        if (v instanceof Double) return (Double) v;
        try { return Decimal.valueOf(String.valueOf(v)); } catch (TypeException e) { return null; }
    }

    private static Integer intOrNull(Decimal d) {
        return d == null ? null : d.intValue();
    }

    /** Discovery returns text fields HTML-escaped (e.g. "&amp;"). */
    private static String unescape(String s) {
        return s == null ? null : s.unescapeHtml4();
    }
}
