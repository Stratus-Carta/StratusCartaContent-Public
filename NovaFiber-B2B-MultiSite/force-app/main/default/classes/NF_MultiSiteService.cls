/**
 * NF_MultiSiteService
 * Multi-site quoting for agents: one customer, many service locations, each priced by its state.
 *
 *  Sites (checkSites): serviceability per address (NF_ServiceabilityService) and the business plans each
 *  address qualifies for (NF_OfferService, NovaFiber Business catalog NF_BIZ, cached per technology profile).
 *
 *  Location prices (statePrices, while browsing): nothing is saved. A configurator session on the
 *  LOCATION PRICING WORKSPACE quote, which holds one Location recipient per state and never any lines,
 *  prices every product with SalesTransactionRecipient = that state's recipient. The quote pricing
 *  procedure's LocationBasedPrice step then reads LocationBasedDecisionTable (ItemLocationPrice__c) with
 *  the recipient's ServiceState (copied to ItemLocationState__c by ApexDmlAttributePreHook, which needs a
 *  real recipient id). Recipients for new states are added on first use.
 *
 *  Site carts (priceCarts): every site's cart is priced the same way, in one configure call.
 *
 *  Quote (saveQuote): Place Sales Transaction with the Quote and, per site, a QuoteLineItemRecipient
 *  (service address) and a QuoteLineGroup; then the lines with their site's recipient and group (real ids,
 *  for the pricing pre-hook), configured and priced by Revenue Cloud.
 */
public inherited sharing class NF_MultiSiteService {

    public static final String PRICING_WORKSPACE = 'NovaFiber Location Pricing Workspace';
    @TestVisible private static final Integer MAX_SITES = 25;          // agents
    @TestVisible private static final Integer MAX_GUEST_SITES = 10;    // site visitors
    /** Quote names start with this; NF_OrderService names a visitor's prospect account after the business at order time. */
    public static final String QUOTE_PREFIX = 'NovaFiber Multi-site - ';
    @TestVisible private static final Integer MAX_CHECK_BATCH = 10;
    private static final Integer MAX_STATES = 10;
    private static final Integer MAX_PRODUCTS = 60;
    private static final Integer MAX_LINES = 400;
    private static final String PATH_CONFIGURE = '/connect/cpq/configurator/actions/configure';
    private static final String PATH_PLACE = '/connect/rev/sales-transaction/actions/place';
    private static final Pattern STATE = Pattern.compile('[A-Z]{2}');

    // ── Sites ────────────────────────────────────────────────────────────────

    public static List<NF_JourneyModels.SiteResult> checkSites(List<NF_JourneyModels.SiteInput> sites) {
        if (sites == null || sites.isEmpty()) throw new NF_JourneyModels.JourneyException('Add at least one site.');
        if (sites.size() > MAX_CHECK_BATCH) {
            throw new NF_JourneyModels.JourneyException('Check at most ' + MAX_CHECK_BATCH + ' sites at a time.');
        }
        List<NF_JourneyModels.SiteResult> out = new List<NF_JourneyModels.SiteResult>();
        for (NF_JourneyModels.SiteInput s : sites) {
            NF_JourneyModels.SiteResult r = new NF_JourneyModels.SiteResult();
            r.key = s.key;
            r.name = s.name;
            try {
                if (s.address == null) throw new NF_JourneyModels.JourneyException('The site has no address.');
                s.address.state = normState(s.address.state);
                if (String.isBlank(s.address.country)) s.address.country = 'US';
                r.serviceability = NF_ServiceabilityService.check(s.address);
                r.offers = NF_OfferService.getOffers(r.serviceability, true, NF_OfferService.BUSINESS_CATALOG_CODE);
            } catch (NF_JourneyModels.JourneyException e) {
                r.error = e.getMessage();
            }
            out.add(r);
        }
        return out;
    }

    // ── Location prices (browse) ─────────────────────────────────────────────

    /** List price of each product in each state, from LocationBasedDecisionTable via the quote pricing procedure. */
    public static List<NF_JourneyModels.StatePrices> statePrices(NF_JourneyModels.StatePriceRequest req) {
        if (req == null || req.states == null || req.states.isEmpty() || req.productIds == null || req.productIds.isEmpty()) {
            throw new NF_JourneyModels.JourneyException('Choose the states and products to price.');
        }
        Set<String> states = new Set<String>();
        for (String st : req.states) states.add(normState(st));
        Set<Id> productIds = new Set<Id>();
        for (String p : req.productIds) productIds.add(toId(p, Product2.SObjectType, 'product'));
        if (states.size() > MAX_STATES) throw new NF_JourneyModels.JourneyException('Price at most ' + MAX_STATES + ' states at a time.');
        if (productIds.size() > MAX_PRODUCTS) throw new NF_JourneyModels.JourneyException('Price at most ' + MAX_PRODUCTS + ' products at a time.');

        // Cached journey: a state's price list is reused for the day.
        String signature = String.join(sortedIds(productIds), ',');
        Map<String, NF_JourneyModels.StatePrices> byState = new Map<String, NF_JourneyModels.StatePrices>();
        List<String> missing = new List<String>();
        for (String st : states) {
            String hit = NF_JourneyCache.read(priceKey(st, signature));
            if (hit == null) {
                missing.add(st);
            } else {
                byState.put(st, (NF_JourneyModels.StatePrices) JSON.deserialize(hit, NF_JourneyModels.StatePrices.class));
            }
        }
        if (!byState.isEmpty()) {
            NF_Trace.note('CACHE', 'Location prices from cache', String.join(new List<String>(byState.keySet()), ', ')
                + ' · priced earlier today by Revenue Cloud (TTL ' + NF_JourneyCache.TTL_CATALOG + 's)');
        }
        if (!missing.isEmpty()) {
            Map<String, Id> recipients = pricingRecipients(new Set<String>(missing));
            Map<Id, PricebookEntry> pbeByProduct = new Map<Id, PricebookEntry>();
            for (PricebookEntry e : [
                SELECT Id, Product2Id, ProductSellingModelId, ProductSellingModel.SellingModelType
                FROM PricebookEntry
                WHERE Pricebook2Id = :NF_QuoteService.pricebookId() AND Product2Id IN :productIds AND IsActive = true
            ]) pbeByProduct.put(e.Product2Id, e);

            Id wsId = recipients.get('_quote');
            List<Object> added = new List<Object>();
            Map<String, String[]> keyByNode = new Map<String, String[]>();
            String today = String.valueOf(Date.today());
            Integer n = 0;
            for (String st : missing) {
                for (PricebookEntry e : pbeByProduct.values()) {
                    String nodeId = 'nfL' + st + (++n);
                    keyByNode.put(nodeId, new String[]{ st, e.Product2Id });
                    added.add(node(wsId, nodeId, e.Product2Id, e.Id, e.ProductSellingModelId,
                        e.ProductSellingModel.SellingModelType, 1, null, today, recipients.get(st)));
                }
            }
            Map<String, Object> res = NF_RevCloudApi.post(PATH_CONFIGURE, configureBody(wsId, added, false),
                'Configurator · location prices · ' + String.join(missing, ', ') + ' · ' + pbeByProduct.size()
                + ' product(s) · LocationBasedDecisionTable · nothing saved');
            assertConfigured(res);
            for (String st : missing) {
                NF_JourneyModels.StatePrices sp = new NF_JourneyModels.StatePrices();
                sp.state = st;
                sp.prices = new Map<String, Decimal>();
                byState.put(st, sp);
            }
            for (Map<String, Object> li : lines(res)) {
                String[] key = keyByNode.get(str(li, 'id'));
                if (key == null) continue;
                Decimal price = dec(li, 'NetUnitPrice') != null ? dec(li, 'NetUnitPrice') : dec(li, 'ListPrice');
                byState.get(key[0]).prices.put(key[1], price);
            }
            for (String st : missing) {
                NF_JourneyCache.put(priceKey(st, signature), JSON.serialize(byState.get(st)), NF_JourneyCache.TTL_CATALOG);
            }
        }
        List<NF_JourneyModels.StatePrices> out = new List<NF_JourneyModels.StatePrices>();
        for (String st : states) out.add(byState.get(st));
        return out;
    }

    private static String priceKey(String state, String signature) {
        return NF_JourneyCache.key('locprice', Date.today() + '#' + state + '#' + signature);
    }

    /**
     * The workspace's Location recipient per state (and '_quote' → the workspace quote id), creating the
     * workspace and any missing recipients through Place Sales Transaction. Recipients carry only a state.
     */
    @TestVisible
    private static Map<String, Id> pricingRecipients(Set<String> states) {
        Map<String, Id> out = new Map<String, Id>();
        List<Quote> ws = [SELECT Id FROM Quote WHERE Name = :PRICING_WORKSPACE AND NF_Channel__c = null ORDER BY CreatedDate ASC LIMIT 1];
        if (!ws.isEmpty()) {
            for (QuoteLineItemRecipient r : [SELECT Id, ServiceState FROM QuoteLineItemRecipient WHERE QuoteId = :ws[0].Id]) {
                if (r.ServiceState != null && !out.containsKey(r.ServiceState)) out.put(r.ServiceState, r.Id);
            }
        }
        List<String> missing = new List<String>();
        for (String st : states) if (!out.containsKey(st)) missing.add(st);
        if (!missing.isEmpty()) {
            List<Object> records = new List<Object>();
            if (ws.isEmpty()) {
                List<Quote> cartWs = [SELECT QuoteAccountId FROM Quote WHERE Name = :NF_QuoteService.WORKSPACE_NAME LIMIT 1];
                if (cartWs.isEmpty()) throw new NF_JourneyModels.JourneyException('Location pricing is not set up yet.');
                records.add(new Map<String, Object>{ 'referenceId' => 'refQuote', 'record' => new Map<String, Object>{
                    'attributes' => new Map<String, Object>{ 'type' => 'Quote', 'method' => 'POST' },
                    'Name' => PRICING_WORKSPACE, 'Pricebook2Id' => NF_QuoteService.pricebookId(),
                    'QuoteAccountId' => cartWs[0].QuoteAccountId, 'StartDate' => String.valueOf(Date.today()) } });
            } else {
                records.add(new Map<String, Object>{ 'referenceId' => 'refQuote', 'record' => new Map<String, Object>{
                    'attributes' => new Map<String, Object>{ 'type' => 'Quote', 'method' => 'PATCH', 'id' => ws[0].Id } } });
            }
            for (String st : missing) {
                records.add(new Map<String, Object>{ 'referenceId' => 'ref' + st, 'record' => new Map<String, Object>{
                    'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineItemRecipient', 'method' => 'POST' },
                    'QuoteId' => ws.isEmpty() ? '@{refQuote.id}' : (Object) ws[0].Id,
                    'Name' => 'Pricing location ' + st, 'RecipientType' => 'Location',
                    'ServiceState' => st, 'ServiceCountry' => 'US' } });
            }
            Map<String, Object> placed = NF_RevCloudApi.post(PATH_PLACE, new Map<String, Object>{
                'pricingPref' => 'Skip', 'configurationPref' => new Map<String, Object>{ 'configurationMethod' => 'Skip' },
                'graph' => new Map<String, Object>{ 'graphId' => 'nfLocationRecipients', 'records' => records }
            }, 'Place Sales Transaction · location pricing recipient(s) ' + String.join(missing, ', '));
            assertPlaced(placed, true);
            Id wsId = (Id) String.valueOf(placed.get('salesTransactionId'));
            ws = new List<Quote>{ new Quote(Id = wsId) };
            for (QuoteLineItemRecipient r : [SELECT Id, ServiceState FROM QuoteLineItemRecipient WHERE QuoteId = :wsId AND ServiceState IN :missing]) {
                out.put(r.ServiceState, r.Id);
            }
        }
        out.put('_quote', ws[0].Id);
        return out;
    }

    // ── Site carts ───────────────────────────────────────────────────────────

    /** Every site's cart priced for its state in one configure call: lines, totals and messages per site. */
    public static List<NF_JourneyModels.SiteSummary> priceCarts(List<NF_JourneyModels.SiteCart> sites,
                                                               NF_JourneyModels.JourneyContext ctx) {
        List<Prepared> prepared = prepare(sites, ctx, false);
        Set<String> states = new Set<String>();
        for (Prepared p : prepared) states.add(p.state);
        Map<String, Id> recipients = pricingRecipients(states);
        Id wsId = recipients.get('_quote');

        List<Object> added = new List<Object>();
        Map<String, Prepared> siteByNode = new Map<String, Prepared>();
        String today = String.valueOf(Date.today());
        String generation = String.valueOf(Math.abs(Crypto.getRandomInteger())).left(5);
        for (Integer i = 0; i < prepared.size(); i++) {
            Prepared p = prepared[i];
            addCartNodes(added, siteByNode, p, 'nfS' + generation + 's' + i + 'i', wsId, today, recipients.get(p.state));
        }
        Map<String, Object> res = NF_RevCloudApi.post(PATH_CONFIGURE, configureBody(wsId, added, true),
            'Configurator · ' + prepared.size() + ' site cart(s) · ' + added.size() + ' node(s) · priced per state · nothing saved');
        assertConfigured(res);

        Map<String, NF_JourneyModels.SiteSummary> bySite = new Map<String, NF_JourneyModels.SiteSummary>();
        for (Prepared p : prepared) bySite.put(p.site.key, emptySummary(p));
        List<Map<String, Object>> all = lines(res);
        Map<String, NF_ConfigRules.Result> rulesBySite = new Map<String, NF_ConfigRules.Result>();
        // CML rules may have added lines (engine ids) or removed ours: each site follows what Revenue Cloud left.
        for (Prepared p : prepared) {
            NF_ConfigRules.Result rules = NF_ConfigRules.read(all, res.get('uiTreatments'), p.itemByRoot, p.offers);
            rulesBySite.put(p.site.key, rules);
            NF_JourneyModels.SiteSummary s = bySite.get(p.site.key);
            s.ruleAdjustments = rules.adjustments;
            s.hiddenOptions = rules.hidden;
            for (Map<String, Object> li : all) {
                String id = str(li, 'id');
                if (!rules.rootByLine.containsKey(id)) continue;
                addLine(s, id, rules.parentByLine.get(id), str(li, 'Product'), str(li, 'ProductName'),
                    dec(li, 'Quantity'), dec(li, 'ListPrice'), dec(li, 'Discount'), dec(li, 'NetTotalPrice'),
                    str(li, 'SellingModelType'));
            }
        }
        Map<String, Object> msgs = asMap(res.get('messages'));
        for (String nodeId : msgs.keySet()) {
            Prepared p = siteByNode.get(nodeId.replaceAll('c\\d+r?$', ''));
            if (p == null) continue;
            NF_JourneyModels.SiteSummary s = bySite.get(p.site.key);
            for (Object o : asList(msgs.get(nodeId))) {
                NF_JourneyModels.CartMessage cm = new NF_JourneyModels.CartMessage();
                cm.itemKey = p.itemKeyByNode.get(nodeId.replaceAll('c\\d+r?$', ''));
                cm.severity = str(asMap(o), 'messageType') == null ? 'info' : str(asMap(o), 'messageType').toLowerCase();
                cm.category = str(asMap(o), 'category');
                cm.message = str(asMap(o), 'message');
                s.messages.add(cm);
                s.hasErrors |= cm.severity == 'error';
            }
        }
        List<NF_JourneyModels.SiteSummary> out = new List<NF_JourneyModels.SiteSummary>();
        for (Prepared p : prepared) {
            NF_JourneyModels.SiteSummary s = bySite.get(p.site.key);
            NF_ConfigRules.Result rules = rulesBySite.get(p.site.key);
            List<NF_JourneyModels.CartMessage> kept = NF_ConfigRules.withoutStale(s.messages, rules);
            s.messages = new List<NF_JourneyModels.CartMessage>();
            s.hasErrors = false;
            for (NF_JourneyModels.CartMessage m : kept) {
                if (m.category == 'cml') continue;
                s.messages.add(m);
                s.hasErrors |= m.severity == 'error';
            }
            s.messages.addAll(rules.notes);
            out.add(s);
        }
        return out;
    }

    // ── Quote ────────────────────────────────────────────────────────────────

    public static NF_JourneyModels.MultiSiteQuote saveQuote(NF_JourneyModels.MultiSiteRequest req,
                                                           NF_JourneyModels.JourneyContext ctx) {
        if (req == null) throw new NF_JourneyModels.JourneyException('Nothing to quote.');
        List<Prepared> prepared = prepare(req.sites, ctx, true);
        Id accountId = account(req, prepared[0], ctx);
        String today = String.valueOf(Date.today());

        // 1. Quote + per site: service location recipient and line group
        List<Object> header = new List<Object>{ new Map<String, Object>{ 'referenceId' => 'refQuote', 'record' => new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'Quote', 'method' => 'POST' },
            'Name' => (QUOTE_PREFIX + companyName(req, prepared) + ' - ' + prepared.size() + ' sites').left(80),
            'Pricebook2Id' => NF_QuoteService.pricebookId(),
            'QuoteAccountId' => accountId,
            'StartDate' => today,   // the org trigger QuoteLineItemAfterAll copies it onto the lines
            'ExpirationDate' => String.valueOf(Date.today().addDays(30)),
            'NF_Channel__c' => ctx.channel } } };
        for (Integer i = 0; i < prepared.size(); i++) {
            Prepared p = prepared[i];
            NF_JourneyModels.Address a = p.svc.address;
            NF_JourneyModels.Technology primary = p.svc.technologies.isEmpty() ? null : p.svc.technologies[0];
            p.label = siteLabel(i, p.site.name, a);
            header.add(new Map<String, Object>{ 'referenceId' => 'refSite' + i, 'record' => new Map<String, Object>{
                'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineItemRecipient', 'method' => 'POST' },
                'QuoteId' => '@{refQuote.id}',
                'Name' => p.label,
                'RecipientType' => 'Location',
                'ServiceStreet' => String.isBlank(a.unit) ? a.street : a.street + '\n' + a.unit,
                'ServiceCity' => a.city,
                'ServiceState' => a.state,
                'ServicePostalCode' => a.postalCode,
                'ServiceCountry' => a.country,
                'ServiceAddrValidationResult' => 'Success',
                'ServiceabilityCheckDate' => DateTime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
                'ServiceabilityData' => JSON.serialize(p.svc.technologies),
                'MaxDownloadSpeed' => primary == null ? null : primary.maxDownloadMbps + ' Mbps',
                'MaxUploadSpeed' => primary == null ? null : primary.maxUploadMbps + ' Mbps' } });
            header.add(new Map<String, Object>{ 'referenceId' => 'refGroup' + i, 'record' => new Map<String, Object>{
                'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineGroup', 'method' => 'POST' },
                'QuoteId' => '@{refQuote.id}',
                'Name' => p.label } });
        }
        Map<String, Object> placed = NF_RevCloudApi.post(PATH_PLACE, new Map<String, Object>{
            'pricingPref' => 'Skip',
            'configurationPref' => new Map<String, Object>{ 'configurationMethod' => 'Skip' },
            'graph' => new Map<String, Object>{ 'graphId' => 'nfMsHeader', 'records' => header }
        }, 'Place Sales Transaction · Quote + ' + prepared.size() + ' site(s): service location + line group');
        assertPlaced(placed, ctx.isAgent);
        Id quoteId = (Id) String.valueOf(placed.get('salesTransactionId'));

        Map<String, Id> recipientByLabel = new Map<String, Id>();
        for (QuoteLineItemRecipient r : [SELECT Id, Name FROM QuoteLineItemRecipient WHERE QuoteId = :quoteId]) recipientByLabel.put(r.Name, r.Id);
        Map<String, Id> groupByLabel = new Map<String, Id>();
        for (QuoteLineGroup g : [SELECT Id, Name FROM QuoteLineGroup WHERE QuoteId = :quoteId]) groupByLabel.put(g.Name, g.Id);

        // 2. The lines of every site, with its recipient (real id: the pricing pre-hook reads its state) and group
        List<Object> records = new List<Object>{ new Map<String, Object>{ 'referenceId' => quoteId, 'record' => new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'Quote', 'method' => 'PATCH', 'id' => quoteId },
            'StartDate' => today } } };
        Integer lineCount = 0;
        for (Integer i = 0; i < prepared.size(); i++) {
            Prepared p = prepared[i];
            Id recipientId = recipientByLabel.get(p.label);
            Id groupId = groupByLabel.get(p.label);
            if (recipientId == null || groupId == null) {
                throw new NF_JourneyModels.JourneyException('We could not save the sites on the quote. Please try again.');
            }
            Integer n = 0;
            for (NF_JourneyModels.CartItem item : p.cart.items) {
                NF_JourneyModels.Offer offer = p.offers.get(item.productId);
                String parentRef = 'refS' + i + 'L' + (++n);
                records.add(lineRecord(quoteId, parentRef, item.productId, offer.priceBookEntryId, offer.sellingModelType,
                    item.quantity, item.discountPercent, today, recipientId, groupId));
                lineCount++;
                Integer m = 0;
                for (NF_JourneyModels.Option op : NF_QuoteService.optionsFor(offer, item).values()) {
                    String childRef = parentRef + 'c' + (++m);
                    records.add(lineRecord(quoteId, childRef, op.productId, op.priceBookEntryId, op.sellingModelType,
                        NF_QuoteService.quantityOf(item, op), item.discountPercent, today, recipientId, groupId));
                    lineCount++;
                    records.add(new Map<String, Object>{ 'referenceId' => childRef + 'r', 'record' => new Map<String, Object>{
                        'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineRelationship', 'method' => 'POST' },
                        'MainQuoteLineId' => '@{' + parentRef + '.id}',
                        'AssociatedQuoteLineId' => '@{' + childRef + '.id}',
                        'ProductRelatedComponentId' => op.componentId,
                        'ProductRelationshipTypeId' => op.relationshipTypeId,
                        'AssociatedQuoteLinePricing' => 'NotIncludedInBundlePrice' } });
                }
            }
        }
        if (lineCount > MAX_LINES) {
            throw new NF_JourneyModels.JourneyException('A multi-site quote can hold at most ' + MAX_LINES + ' lines; split the sites over two quotes.');
        }
        Map<String, Object> placedLines = NF_RevCloudApi.post(PATH_PLACE, new Map<String, Object>{
            'pricingPref' => 'System',
            'configurationPref' => new Map<String, Object>{
                'configurationMethod' => 'System',
                'configurationOptions' => new Map<String, Object>{
                    'validateProductCatalog' => true, 'executeConfigurationRules' => true, 'addDefaultConfiguration' => false }
            },
            'graph' => new Map<String, Object>{ 'graphId' => 'nfMsLines', 'records' => records }
        }, 'Place Sales Transaction · ' + lineCount + ' line(s) over ' + prepared.size() + ' site(s) · rules + location pricing');
        assertPlaced(placedLines, ctx.isAgent);
        return summarize(quoteId, prepared);
    }

    /** The saved quote per site: lines grouped by their service location recipient. */
    @TestVisible
    private static NF_JourneyModels.MultiSiteQuote summarize(Id quoteId, List<Prepared> prepared) {
        Quote q = [SELECT Id, QuoteNumber, QuoteAccountId FROM Quote WHERE Id = :quoteId];
        NF_JourneyModels.MultiSiteQuote out = new NF_JourneyModels.MultiSiteQuote();
        out.quoteId = q.Id;
        out.quoteNumber = q.QuoteNumber;
        out.accountId = q.QuoteAccountId;
        out.monthlyTotal = 0;
        out.oneTimeTotal = 0;
        out.sites = new List<NF_JourneyModels.SiteSummary>();

        Map<String, NF_JourneyModels.SiteSummary> byLabel = new Map<String, NF_JourneyModels.SiteSummary>();
        for (Prepared p : prepared) {
            NF_JourneyModels.SiteSummary s = emptySummary(p);
            byLabel.put(p.label, s);
            out.sites.add(s);
        }
        Map<Id, Id> parentByChild = new Map<Id, Id>();
        for (QuoteLineRelationship rel : [
            SELECT MainQuoteLineId, AssociatedQuoteLineId FROM QuoteLineRelationship WHERE MainQuoteLine.QuoteId = :quoteId
        ]) parentByChild.put(rel.AssociatedQuoteLineId, rel.MainQuoteLineId);
        List<QuoteLineItem> priced = [
            SELECT Id, Product2Id, Product2.Name, Quantity, UnitPrice, Discount, TotalPrice, NetTotalPrice, SellingModelType,
                   QuoteLineItemRecipient.Name
            FROM QuoteLineItem WHERE QuoteId = :quoteId ORDER BY LineNumber ASC
        ];
        if (NF_Trace.isEnabled()) {
            NF_Trace.Entry t = NF_Trace.note('SOQL', 'Saved multi-site quote lines', priced.size() + ' rows · Quote ' + q.QuoteNumber);
            t.responseJson = NF_Trace.toJson(priced);
        }
        for (QuoteLineItem li : priced) {
            NF_JourneyModels.SiteSummary s = byLabel.get(li.QuoteLineItemRecipient?.Name);
            if (s == null) continue;
            addLine(s, li.Id, parentByChild.get(li.Id), li.Product2Id, li.Product2.Name, li.Quantity, li.UnitPrice,
                li.Discount, li.NetTotalPrice != null ? li.NetTotalPrice : li.TotalPrice, li.SellingModelType);
        }
        for (NF_JourneyModels.SiteSummary s : out.sites) {
            out.monthlyTotal += s.monthlyTotal;
            out.oneTimeTotal += s.oneTimeTotal;
        }
        return out;
    }

    // ── Validation ───────────────────────────────────────────────────────────

    @TestVisible
    private class Prepared {
        NF_JourneyModels.SiteCart site;
        NF_JourneyModels.ServiceabilityResult svc;
        Map<String, NF_JourneyModels.Offer> offers;
        NF_JourneyModels.CartRequest cart;
        String state;
        String label;
        Map<String, String> itemKeyByNode = new Map<String, String>();
        Map<String, NF_JourneyModels.CartItem> itemByRoot = new Map<String, NF_JourneyModels.CartItem>();
    }

    /** Each site checked like a single-site cart: server copy of serviceability, its offers and the cart rules. */
    private static List<Prepared> prepare(List<NF_JourneyModels.SiteCart> sites, NF_JourneyModels.JourneyContext ctx,
                                          Boolean enforceBundles) {
        if (sites == null || sites.isEmpty()) throw new NF_JourneyModels.JourneyException('Add at least one site with plans.');
        Integer maxSites = ctx.isAgent == true ? MAX_SITES : MAX_GUEST_SITES;
        if (sites.size() > maxSites) throw new NF_JourneyModels.JourneyException('A multi-site quote can hold at most ' + maxSites + ' sites.');
        List<Prepared> out = new List<Prepared>();
        Set<String> keys = new Set<String>();
        for (NF_JourneyModels.SiteCart site : sites) {
            if (String.isBlank(site.key) || !keys.add(site.key)) throw new NF_JourneyModels.JourneyException('Every site needs its own key.');
            String label = String.isBlank(site.name) ? 'A site' : site.name;
            if (site.items == null || site.items.isEmpty()) {
                throw new NF_JourneyModels.JourneyException(label + ' has no plans. Add plans or remove the site.');
            }
            if (site.items.size() > 10) throw new NF_JourneyModels.JourneyException(label + ' can hold at most 10 items.');
            Prepared p = new Prepared();
            p.site = site;
            p.cart = new NF_JourneyModels.CartRequest();
            p.cart.serviceability = site.serviceability;
            p.cart.items = site.items;
            if (site.serviceability == null || site.serviceability.address == null) {
                throw new NF_JourneyModels.JourneyException(label + ' has not been checked for service yet.');
            }
            p.svc = NF_QuoteService.verified(site.serviceability, ctx);
            p.state = normState(p.svc.address.state);
            p.offers = NF_QuoteService.offersFor(p.svc, NF_OfferService.BUSINESS_CATALOG_CODE);
            try {
                NF_QuoteService.validateCart(p.cart, p.offers, ctx, enforceBundles);
            } catch (NF_JourneyModels.JourneyException e) {
                throw new NF_JourneyModels.JourneyException(label + ': ' + e.getMessage());
            }
            out.add(p);
        }
        return out;
    }

    private static Id account(NF_JourneyModels.MultiSiteRequest req, Prepared first, NF_JourneyModels.JourneyContext ctx) {
        if (String.isNotBlank(req.accountId)) {
            if (ctx.canSelectAccount != true) throw new NF_JourneyModels.JourneyException('Selecting an account is not allowed.');
            List<Account> accs = [SELECT Id FROM Account WHERE Id = :req.accountId WITH USER_MODE LIMIT 1];
            if (accs.isEmpty()) throw new NF_JourneyModels.JourneyException('The selected customer account was not found.');
            return accs[0].Id;
        }
        if (String.isBlank(req.companyName)) {
            throw new NF_JourneyModels.JourneyException('Choose the customer account or enter the business name.');
        }
        NF_JourneyModels.Address a = first.svc.address;
        // Visitors get a prospect account (named after the business when they order; cleaned up if abandoned).
        String name = ctx.isAgent == true ? req.companyName.trim()
            : NF_QuoteService.PROSPECT_PREFIX + ' - ' + req.companyName.trim();
        // REST, not DML: Revenue Cloud callouts follow in this transaction.
        Map<String, Object> res = NF_RevCloudApi.post('/sobjects/Account', new Map<String, Object>{
            'Name' => name.left(255),
            'BillingStreet' => a.street, 'BillingCity' => a.city, 'BillingState' => a.state,
            'BillingPostalCode' => a.postalCode, 'BillingCountry' => a.country,
            'AccountSource' => ctx.isAgent == true ? 'Phone Inquiry' : 'Web'
        }, 'Create business account (sObject REST)', new Map<String, String>{ 'Sforce-Duplicate-Rule-Header' => 'allowSave=true' });
        if (res.get('id') == null) throw new NF_JourneyModels.JourneyException('We could not create the customer account. Please try again.');
        return (Id) String.valueOf(res.get('id'));
    }

    private static String companyName(NF_JourneyModels.MultiSiteRequest req, List<Prepared> prepared) {
        if (String.isNotBlank(req.companyName)) return req.companyName.trim();
        if (String.isNotBlank(req.accountId)) {
            List<Account> accs = [SELECT Name FROM Account WHERE Id = :req.accountId LIMIT 1];
            if (!accs.isEmpty()) return accs[0].Name;
        }
        return prepared[0].site.name;
    }

    /** "Site 01 - HQ - 350 5th Ave, New York NY": unique per quote, used to find each site's recipient and group. */
    private static String siteLabel(Integer i, String name, NF_JourneyModels.Address a) {
        String n = String.valueOf(i + 1).leftPad(2, '0');
        String what = String.isBlank(name) ? a.street : name + ' - ' + a.street;
        return ('Site ' + n + ' - ' + what + ', ' + a.city + ' ' + a.state).left(80);
    }

    private static String normState(String st) {
        String s = st == null ? '' : st.trim().toUpperCase();
        if (!STATE.matcher(s).matches()) throw new NF_JourneyModels.JourneyException('Use a 2-letter state code (e.g. NY).');
        return s;
    }

    private static Id toId(String text, SObjectType t, String what) {
        try {
            Id i = Id.valueOf(text);
            if (i.getSObjectType() == t) return i;
        } catch (Exception e) {
            // fall through
        }
        throw new NF_JourneyModels.JourneyException('Unknown ' + what + '.');
    }

    private static List<String> sortedIds(Set<Id> ids) {
        List<String> out = new List<String>();
        for (Id i : ids) out.add(i);
        out.sort();
        return out;
    }

    // ── Configurator nodes / PST records ─────────────────────────────────────

    private static Map<String, Object> configureBody(Id wsId, List<Object> added, Boolean rules) {
        return new Map<String, Object>{
            'transactionId' => wsId,
            'contextResponseType' => 'Full',
            'addedNodes' => added,
            'configuratorOptions' => new Map<String, Object>{
                'executePricing' => true, 'executeConfigurationRules' => rules,
                'addDefaultConfiguration' => false, 'validateProductCatalog' => rules }
        };
    }

    private static void addCartNodes(List<Object> added, Map<String, Prepared> siteByNode, Prepared p, String prefix,
                                     Id wsId, String today, Id recipientId) {
        Integer n = 0;
        for (NF_JourneyModels.CartItem item : p.cart.items) {
            NF_JourneyModels.Offer offer = p.offers.get(item.productId);
            String nodeId = prefix + (++n);
            siteByNode.put(nodeId, p);
            p.itemKeyByNode.put(nodeId, item.key);
            p.itemByRoot.put(nodeId, item);
            added.add(node(wsId, nodeId, item.productId, offer.priceBookEntryId, offer.productSellingModelId,
                offer.sellingModelType, item.quantity, item.discountPercent, today, recipientId));
            Integer m = 0;
            for (NF_JourneyModels.Option op : NF_QuoteService.optionsFor(offer, item).values()) {
                String childId = nodeId + 'c' + (++m);
                siteByNode.put(childId, p);
                added.add(node(wsId, childId, op.productId, op.priceBookEntryId, op.productSellingModelId,
                    op.sellingModelType, NF_QuoteService.quantityOf(item, op), item.discountPercent, today, recipientId));
                added.add(new Map<String, Object>{
                    'path' => new List<Object>{ wsId, childId, childId + 'r' },
                    'addedObject' => new Map<String, Object>{
                        'businessObjectType' => 'QuoteLineRelationship',
                        'id' => childId + 'r',
                        'MainItem' => nodeId,
                        'AssociatedItem' => childId,
                        'ProductRelatedComponent' => op.componentId,
                        'ProductRelationshipType' => op.relationshipTypeId,
                        'AssociatedItemPricing' => 'NotIncludedInBundlePrice',
                        'AssociatedQuantScaleMethod' => 'Proportional'
                    }
                });
            }
        }
    }

    private static Map<String, Object> node(Id wsId, String id, String productId, String pbeId, String psmId,
            String sellingModelType, Integer qty, Decimal discount, String today, Id recipientId) {
        Map<String, Object> o = new Map<String, Object>{
            'businessObjectType' => 'QuoteLineItem',
            'id' => id,
            'SalesTransactionItemSource' => id,
            'SalesTransactionItemParent' => wsId,
            'Product' => productId,
            'PricebookEntry' => pbeId,
            'ProductSellingModel' => psmId,
            'Quantity' => qty,
            'StartDate' => today,
            'PeriodBoundary' => 'Anniversary',
            'SalesTransactionRecipient' => recipientId   // the state for LocationBasedPrice (via the pricing pre-hook)
        };
        if (sellingModelType != 'OneTime') o.put('BillingFrequency', 'Monthly');
        if (discount != null && discount > 0) o.put('Discount', discount);
        return new Map<String, Object>{ 'path' => new List<Object>{ wsId, id }, 'addedObject' => o };
    }

    private static Map<String, Object> lineRecord(Id quoteId, String ref, String productId, String pbeId, String sellingModelType,
            Integer qty, Decimal discount, String today, Id recipientId, Id groupId) {
        Map<String, Object> r = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineItem', 'method' => 'POST' },
            'QuoteId' => quoteId,
            'Product2Id' => productId,
            'PricebookEntryId' => pbeId,
            'Quantity' => qty,
            'StartDate' => today,
            'PeriodBoundary' => 'Anniversary',
            'QuoteLineItemRecipientId' => recipientId,
            'QuoteLineGroupId' => groupId
        };
        if (sellingModelType != 'OneTime') r.put('BillingFrequency', 'Monthly');
        if (discount != null && discount > 0) r.put('Discount', discount);
        return new Map<String, Object>{ 'referenceId' => ref, 'record' => r };
    }

    private static void assertPlaced(Map<String, Object> placed, Boolean showDetail) {
        if (placed.get('isSuccess') == true && placed.get('salesTransactionId') != null) return;
        String detail = NF_RevCloudApi.firstError(placed.get('errorResponse'));
        System.debug(LoggingLevel.ERROR, 'NF multi-site place sales transaction failed: ' + detail);
        throw new NF_JourneyModels.JourneyException('We could not save the multi-site quote. ' + (showDetail ? detail : 'Please try again.'));
    }

    private static void assertConfigured(Map<String, Object> res) {
        if (res.get('success') != false) return;
        String detail = NF_RevCloudApi.firstError(res.get('errors'));
        System.debug(LoggingLevel.ERROR, 'NF multi-site configurator failed: ' + detail);
        throw new NF_JourneyModels.JourneyException('Revenue Cloud could not price the sites: ' + detail);
    }

    // ── Summaries ────────────────────────────────────────────────────────────

    private static NF_JourneyModels.SiteSummary emptySummary(Prepared p) {
        NF_JourneyModels.SiteSummary s = new NF_JourneyModels.SiteSummary();
        s.key = p.site.key;
        s.name = p.site.name;
        s.state = p.state;
        s.monthlyTotal = 0;
        s.oneTimeTotal = 0;
        s.lines = new List<NF_JourneyModels.QuoteLine>();
        s.messages = new List<NF_JourneyModels.CartMessage>();
        s.hasErrors = false;
        return s;
    }

    private static void addLine(NF_JourneyModels.SiteSummary s, String lineId, String parentLineId, String productId,
            String productName, Decimal qty, Decimal listPrice, Decimal discount, Decimal netTotal, String sellingModelType) {
        NF_JourneyModels.QuoteLine l = new NF_JourneyModels.QuoteLine();
        l.lineId = lineId;
        l.parentLineId = parentLineId;
        l.productId = productId;
        l.productName = productName;
        l.quantity = qty;
        l.listPrice = listPrice;
        l.discountPercent = discount;
        l.netTotal = netTotal;
        l.chargeType = sellingModelType == 'OneTime' ? 'One-Time' : 'Monthly';
        s.lines.add(l);
        Decimal net = netTotal == null ? 0 : netTotal.setScale(2, RoundingMode.HALF_UP);
        if (l.chargeType == 'One-Time') s.oneTimeTotal += net; else s.monthlyTotal += net;
    }

    // ── JSON helpers ─────────────────────────────────────────────────────────

    private static List<Map<String, Object>> lines(Map<String, Object> res) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Object st : asList(asMap(res.get('transactionContext')).get('SalesTransaction'))) {
            for (Object li : asList(asMap(st).get('SalesTransactionItem'))) {
                if (li instanceof Map<String, Object>) out.add((Map<String, Object>) li);
            }
        }
        return out;
    }

    private static Map<String, Object> asMap(Object o) {
        return o instanceof Map<String, Object> ? (Map<String, Object>) o : new Map<String, Object>();
    }

    private static List<Object> asList(Object o) {
        return o instanceof List<Object> ? (List<Object>) o : new List<Object>();
    }

    private static String str(Map<String, Object> m, String key) {
        Object v = m.get(key);
        return v == null ? null : String.valueOf(v);
    }

    private static Decimal dec(Map<String, Object> m, String key) {
        Object v = m.get(key);
        if (v == null) return null;
        try { return Decimal.valueOf(String.valueOf(v)); } catch (TypeException e) { return null; }
    }
}
