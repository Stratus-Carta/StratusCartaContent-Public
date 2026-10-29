/**
 * NF_QuoteService
 * Cart and quote for the journey. Everything runs as Revenue Cloud REST calls through the
 * NF_RevenueCloud named credential, so it works the same, synchronously, for agents and guests.
 *
 *  Cart (openSession / syncCart, every cart change): Revenue Cloud configurator sessions on one shared
 *  WORKSPACE quote. A configurator session is a Context Service context: in memory, private to the
 *  session, and only written to its quote when saved. The journey never saves to the workspace, so any
 *  number of shoppers configure in parallel on it, it never fills up, and an abandoned cart leaves no
 *  records behind. Each sync replaces the session's lines with the cart (bundle + chosen options +
 *  QuoteLineRelationship nodes) in one configure call; rules, bundle validation and pricing run in
 *  Revenue Cloud and the prices and messages come back per cart item.
 *
 *  Quote (saveQuote, "See my quote"): the customer's own records are created only now:
 *   1. account (agent-selected, or a "NovaFiber Prospect" via the sObject REST API);
 *   2. Place Sales Transaction: Quote + QuoteLineItemRecipient (service location + serviceability data);
 *   3. Place Sales Transaction: the confirmed lines + bundle relationships, with configuration rules and
 *      pricing (configurationMethod / pricingPref System). Confirming again replaces the lines.
 *  Serviceability is the server's own copy of the check (NF_ServiceabilityService.recall), never the
 *  browser's; offers come from the Discovery cache.
 */
public inherited sharing class NF_QuoteService {

    public static final String PROSPECT_PREFIX = 'NovaFiber Prospect';
    /** Shared configurator workspace (scripts/apex/nf_04_configuratorWorkspace.apex). Never saved to. */
    public static final String WORKSPACE_NAME = 'NovaFiber Configurator Workspace';
    private static final String PATH_CONFIGURE = '/connect/cpq/configurator/actions/configure';
    private static final String PATH_PLACE = '/connect/rev/sales-transaction/actions/place';
    private static final String NODE_PREFIX = 'nfI';

    // ── Cart ─────────────────────────────────────────────────────────────────

    /** Opens a configurator session ahead of the first cart change (the slowest configurator call). */
    public static NF_JourneyModels.QuoteSummary openSession() {
        Draft ws = workspace();
        Map<String, Object> opened = open(ws);
        NF_JourneyModels.QuoteSummary s = emptySummary();
        s.contextId = String.valueOf(opened.get('transactionContextId'));
        return s;
    }

    public static NF_JourneyModels.QuoteSummary syncCart(NF_JourneyModels.CartRequest cart,
                                                        NF_JourneyModels.JourneyContext ctx) {
        checkCart(cart);
        NF_JourneyModels.ServiceabilityResult svc = verified(cart.serviceability, ctx);
        Map<String, NF_JourneyModels.Offer> offers = offersFor(svc);
        // Cart edits let the configurator judge the bundle (its messages show on the item).
        validateCart(cart, offers, ctx, false);
        Id confirmed = toQuoteId(cart.quoteId);

        // Cached journey: a cart the configurator already priced (same items, options, discounts,
        // technology profile and day) is answered from the cache; the session is left as it is.
        String pricedKey = NF_JourneyCache.key('cart', cartSignature(cart, svc));
        String hit = NF_JourneyCache.read(pricedKey);
        if (hit != null) {
            NF_JourneyModels.QuoteSummary cached = fromCachedCart(hit, cart);
            cached.quoteId = confirmed;
            NF_Trace.note('CACHE', 'Priced cart from cache', cart.items.size() + ' item(s) · configured and priced earlier by'
                + ' Revenue Cloud (TTL ' + NF_JourneyCache.TTL_PRICED_CART + 's)');
            return cached;
        }
        Session session = configure(workspace(), cart, offers);
        NF_JourneyModels.QuoteSummary live = fromContext(session);
        live.sessionLineIds = session.sessionLineIds;
        NF_JourneyCache.put(pricedKey, toCachedCart(live, cart), NF_JourneyCache.TTL_PRICED_CART);
        live.quoteId = confirmed;
        return live;
    }

    /** What makes two carts price the same: technology profile, day and each item's exact configuration. */
    private static String cartSignature(NF_JourneyModels.CartRequest cart, NF_JourneyModels.ServiceabilityResult svc) {
        List<String> techs = new List<String>();
        for (NF_JourneyModels.Technology t : svc.technologies) techs.add(t.technology + '|' + t.maxDownloadMbps + '|' + t.installType);
        techs.sort();
        List<String> items = new List<String>();
        for (NF_JourneyModels.CartItem item : cart.items) {
            List<String> opts = new List<String>();
            if (item.options != null) {
                for (NF_JourneyModels.SelectedOption so : item.options) opts.add(so.componentId + ':' + so.quantity);
            }
            opts.sort();
            items.add(item.productId + '*' + item.quantity + '%' + item.discountPercent + '[' + String.join(opts, ',') + ']');
        }
        return Date.today() + '#' + String.join(techs, ';') + '#' + String.join(items, '/');
    }

    /** Stores a priced cart with item positions instead of this shopper's item keys. */
    private static String toCachedCart(NF_JourneyModels.QuoteSummary live, NF_JourneyModels.CartRequest cart) {
        Map<String, String> positionByKey = new Map<String, String>();
        for (Integer i = 0; i < cart.items.size(); i++) positionByKey.put(cart.items[i].key, String.valueOf(i));
        NF_JourneyModels.QuoteSummary copy = (NF_JourneyModels.QuoteSummary) JSON.deserialize(JSON.serialize(live), NF_JourneyModels.QuoteSummary.class);
        copy.contextId = null;
        copy.sessionLineIds = null;
        copy.quoteId = null;
        for (NF_JourneyModels.QuoteLine l : copy.lines) l.itemKey = positionByKey.get(l.itemKey);
        for (NF_JourneyModels.CartMessage m : copy.messages) m.itemKey = m.itemKey == null ? null : positionByKey.get(m.itemKey);
        if (copy.ruleAdjustments != null) for (NF_JourneyModels.RuleAdjustment r : copy.ruleAdjustments) r.itemKey = positionByKey.get(r.itemKey);
        if (copy.hiddenOptions != null) for (NF_JourneyModels.HiddenOption h : copy.hiddenOptions) h.itemKey = positionByKey.get(h.itemKey);
        return JSON.serialize(copy);
    }

    private static NF_JourneyModels.QuoteSummary fromCachedCart(String payload, NF_JourneyModels.CartRequest cart) {
        NF_JourneyModels.QuoteSummary s = (NF_JourneyModels.QuoteSummary) JSON.deserialize(payload, NF_JourneyModels.QuoteSummary.class);
        for (NF_JourneyModels.QuoteLine l : s.lines) l.itemKey = l.itemKey == null ? null : cart.items[Integer.valueOf(l.itemKey)].key;
        for (NF_JourneyModels.CartMessage m : s.messages) m.itemKey = m.itemKey == null ? null : cart.items[Integer.valueOf(m.itemKey)].key;
        if (s.ruleAdjustments != null) for (NF_JourneyModels.RuleAdjustment r : s.ruleAdjustments) r.itemKey = cart.items[Integer.valueOf(r.itemKey)].key;
        if (s.hiddenOptions != null) for (NF_JourneyModels.HiddenOption h : s.hiddenOptions) h.itemKey = cart.items[Integer.valueOf(h.itemKey)].key;
        s.contextId = cart.contextId;            // the live session is untouched
        s.sessionLineIds = cart.lineIds;
        s.fromCache = true;
        return s;
    }

    // ── Quote ────────────────────────────────────────────────────────────────

    public static NF_JourneyModels.QuoteSummary saveQuote(NF_JourneyModels.CartRequest cart,
                                                         NF_JourneyModels.JourneyContext ctx) {
        checkCart(cart);
        // Realtime journey: the address is checked with the network and the offers asked from Revenue
        // Cloud again before anything is placed. Cached journey: the server's own results are used.
        NF_JourneyModels.ServiceabilityResult svc = NF_JourneyCache.isRealtime()
            ? recheck(cart.serviceability, ctx) : verified(cart.serviceability, ctx);
        Map<String, NF_JourneyModels.Offer> offers = offersFor(svc);
        validateCart(cart, offers, ctx, true);

        Draft draft = reusableDraft(cart, ctx);
        if (draft == null) {
            draft = newDraft(cart, svc, ctx);
        } else {
            replaceLines(draft);
        }
        placeLines(draft, cart, offers, ctx);

        NF_JourneyModels.QuoteSummary saved = summarize(draft.quoteId);
        saved.isSaved = true;
        saved.messages = new List<NF_JourneyModels.CartMessage>();
        saved.hasErrors = false;
        return saved;
    }

    private static void checkCart(NF_JourneyModels.CartRequest cart) {
        if (cart == null || cart.items == null || cart.items.isEmpty()) {
            throw new NF_JourneyModels.JourneyException('Your cart is empty.');
        }
        if (cart.serviceability == null || cart.serviceability.address == null) {
            throw new NF_JourneyModels.JourneyException('Please check your address before building a quote.');
        }
        if (cart.items.size() > 10) throw new NF_JourneyModels.JourneyException('Your cart can hold at most 10 items.');
    }

    public static Map<String, NF_JourneyModels.Offer> offersFor(NF_JourneyModels.ServiceabilityResult svc) {
        return offersFor(svc, NF_OfferService.CATALOG_CODE);
    }

    public static Map<String, NF_JourneyModels.Offer> offersFor(NF_JourneyModels.ServiceabilityResult svc, String catalogCode) {
        Map<String, NF_JourneyModels.Offer> offers = new Map<String, NF_JourneyModels.Offer>();
        for (NF_JourneyModels.OfferCategory c : NF_OfferService.getOffers(svc, true, catalogCode)) {
            for (NF_JourneyModels.Offer o : c.offers) offers.put(o.productId, o);
        }
        return offers;
    }

    // ── Discard ──────────────────────────────────────────────────────────────

    /**
     * Deletes what an unfinished journey created: the confirmed quote (its lines, service location and
     * bundle relationships cascade) and the prospect account when nothing else uses it. Runs as the
     * integration user over REST so guests can discard their own journey. Ordered quotes, the
     * workspace and real customer accounts are never deleted. A cart that was never confirmed has
     * nothing to delete: it only ever lived in a configurator session.
     */
    public static NF_JourneyModels.DiscardResult discard(String quoteIdText, NF_JourneyModels.JourneyContext ctx) {
        NF_JourneyModels.DiscardResult r = new NF_JourneyModels.DiscardResult();
        r.discarded = true;
        r.deleted = new List<String>();
        Id quoteId = toQuoteId(quoteIdText);
        if (quoteId == null) return r;   // nothing was created yet

        List<Quote> qs = [
            SELECT Id, Name, QuoteNumber, Status, NF_Channel__c, QuoteAccountId, QuoteAccount.Name,
                   (SELECT Id FROM QuoteLineItems), (SELECT Id FROM QuoteLineItemRecipients)
            FROM Quote WHERE Id = :quoteId LIMIT 1
        ];
        if (qs.isEmpty()) return r;      // already gone
        Quote q = qs[0];
        Boolean prospect = (q.QuoteAccount?.Name ?? '').startsWith(PROSPECT_PREFIX);
        if (q.NF_Channel__c == null || q.Name == WORKSPACE_NAME || (!ctx.isAgent && !prospect)) {
            throw new NF_JourneyModels.JourneyException('This quote cannot be discarded here.');
        }
        if (q.Status != 'Draft' || [SELECT COUNT() FROM Order WHERE QuoteId = :q.Id] > 0) {
            throw new NF_JourneyModels.JourneyException('This quote has already been ordered, so it is kept.');
        }

        NF_RevCloudApi.del('/sobjects/Quote/' + q.Id,
            'Delete Quote ' + q.QuoteNumber + ' (lines, service location and relationships cascade)');
        NF_Trace.rec('DELETE', 'Quote', q.Id, 'discarded journey: Quote ' + q.QuoteNumber);
        for (QuoteLineItem li : q.QuoteLineItems) NF_Trace.rec('DELETE', 'QuoteLineItem', li.Id, 'cascade');
        for (QuoteLineItemRecipient rc : q.QuoteLineItemRecipients) NF_Trace.rec('DELETE', 'QuoteLineItemRecipient', rc.Id, 'cascade');
        r.deleted.add('Quote ' + q.QuoteNumber + ' with ' + q.QuoteLineItems.size() + ' line(s) and its service location');

        if (prospect && q.QuoteAccountId != null) {
            Id accountId = q.QuoteAccountId;
            Integer inUse = [SELECT COUNT() FROM Quote WHERE QuoteAccountId = :accountId AND Id != :q.Id]
                + [SELECT COUNT() FROM Order WHERE AccountId = :accountId];
            if (inUse == 0) {
                NF_RevCloudApi.del('/sobjects/Account/' + accountId, 'Delete prospect account (no other quotes or orders)');
                NF_Trace.rec('DELETE', 'Account', accountId, 'discarded journey: prospect account');
                r.deleted.add('Prospect account');
            }
        }
        return r;
    }

    private static Id toQuoteId(String text) {
        try {
            Id i = String.isBlank(text) ? null : Id.valueOf(text);
            return i != null && i.getSObjectType() == Quote.SObjectType ? i : null;
        } catch (StringException e) {
            return null;
        }
    }

    // ── Serviceability & validation ──────────────────────────────────────────

    /**
     * The serviceability the server itself issued for this check (kept 30 min), never the browser's
     * copy. Only when that has expired is the address checked with the network again.
     */
    public static NF_JourneyModels.ServiceabilityResult verified(NF_JourneyModels.ServiceabilityResult client,
                                                                 NF_JourneyModels.JourneyContext ctx) {
        NF_JourneyModels.ServiceabilityResult known = NF_ServiceabilityService.recall(client);
        if (known == null) {
            NF_Trace.note('RULE', 'Serviceability re-checked', 'the server copy of this check has expired');
            known = NF_ServiceabilityService.check(client.address);
            if (client.overridden == true && ctx.canOverrideServiceability == true) {
                known = NF_ServiceabilityService.overrideResult(known);
            }
        } else {
            NF_Trace.note('CACHE', 'Serviceability verified (server copy)', known.serviceabilityId
                + ' · the result this server issued is used, not the browser\'s copy · no network call');
        }
        if (known.overridden == true && ctx.canOverrideServiceability != true) {
            throw new NF_JourneyModels.JourneyException('Serviceability override is not allowed.');
        }
        if (known.technologies == null) known.technologies = new List<NF_JourneyModels.Technology>();
        return known;
    }

    private static NF_JourneyModels.ServiceabilityResult recheck(NF_JourneyModels.ServiceabilityResult client,
                                                                NF_JourneyModels.JourneyContext ctx) {
        NF_JourneyModels.ServiceabilityResult fresh = NF_ServiceabilityService.check(client.address);
        if (client.overridden == true) {
            if (ctx.canOverrideServiceability != true) {
                throw new NF_JourneyModels.JourneyException('Serviceability override is not allowed.');
            }
            fresh = NF_ServiceabilityService.overrideResult(fresh);
        }
        return fresh;
    }

    public static void validateCart(NF_JourneyModels.CartRequest cart, Map<String, NF_JourneyModels.Offer> offers,
                                     NF_JourneyModels.JourneyContext ctx, Boolean enforceBundles) {
        for (NF_JourneyModels.CartItem item : cart.items) {
            NF_JourneyModels.Offer offer = offers.get(item.productId);
            if (offer == null) {
                throw new NF_JourneyModels.JourneyException('One of the selected plans is not available at this address.');
            }
            if (item.quantity == null || item.quantity < 1) item.quantity = 1;
            if (offer.isBundle == true) item.quantity = 1;   // bundles are configured one at a time
            if (item.quantity > 5) throw new NF_JourneyModels.JourneyException('You can add at most 5 of ' + offer.name + '.');
            if (item.discountPercent != null && item.discountPercent != 0) {
                if (ctx.canDiscount != true) throw new NF_JourneyModels.JourneyException('Discounts are not allowed.');
                if (item.discountPercent < 0 || item.discountPercent > ctx.maxDiscountPercent) {
                    throw new NF_JourneyModels.JourneyException('Discount must be between 0 and ' + ctx.maxDiscountPercent + '%.');
                }
            }
            Map<String, NF_JourneyModels.Option> chosen = optionsFor(offer, item);   // rejects unknown options
            if (!enforceBundles) continue;
            for (NF_JourneyModels.OptionGroup g : offer.groups) {
                Integer count = 0;
                for (NF_JourneyModels.Option op : g.options) {
                    if (!chosen.containsKey(op.componentId)) {
                        if (op.isRequired) throw new NF_JourneyModels.JourneyException(op.name + ' is required with ' + offer.name + '.');
                        continue;
                    }
                    count++;
                    Integer qty = quantityOf(item, op);
                    if (qty < op.minQuantity || qty > op.maxQuantity) {
                        throw new NF_JourneyModels.JourneyException(op.name + ' quantity must be between '
                            + op.minQuantity + ' and ' + op.maxQuantity + '.');
                    }
                }
                if (count < g.minOptions) {
                    throw new NF_JourneyModels.JourneyException('Please choose ' + g.minOptions + ' option(s) for ' + g.name + '.');
                }
                if (g.maxOptions != null && count > g.maxOptions) {
                    throw new NF_JourneyModels.JourneyException('You can choose at most ' + g.maxOptions + ' option(s) for ' + g.name + '.');
                }
            }
        }
    }

    /** Selected options of an item that belong to the offer, keyed by component id. Unknown ids are rejected. */
    public static Map<String, NF_JourneyModels.Option> optionsFor(NF_JourneyModels.Offer offer, NF_JourneyModels.CartItem item) {
        Map<String, NF_JourneyModels.Option> byComponent = new Map<String, NF_JourneyModels.Option>();
        for (NF_JourneyModels.OptionGroup g : offer.groups) {
            for (NF_JourneyModels.Option op : g.options) byComponent.put(op.componentId, op);
        }
        Map<String, NF_JourneyModels.Option> chosen = new Map<String, NF_JourneyModels.Option>();
        if (item.options != null) {
            for (NF_JourneyModels.SelectedOption so : item.options) {
                NF_JourneyModels.Option op = byComponent.get(so.componentId);
                if (op == null) throw new NF_JourneyModels.JourneyException('An add-on you selected is not available for ' + offer.name + '.');
                chosen.put(so.componentId, op);
            }
        }
        return chosen;
    }

    public static Integer quantityOf(NF_JourneyModels.CartItem item, NF_JourneyModels.Option op) {
        for (NF_JourneyModels.SelectedOption so : item.options) {
            if (so.componentId == op.componentId) {
                return op.isQuantityEditable && so.quantity != null ? so.quantity : op.defaultQuantity;
            }
        }
        return 0;
    }

    // ── Quotes: workspace and the customer's quote ───────────────────────────

    private class Draft {
        Id quoteId;
        String quoteNumber;
        Id accountId;
        Id recipientId;
    }

    private static Draft workspaceCache;

    private static Draft workspace() {
        if (workspaceCache != null) return workspaceCache;
        List<Quote> qs = [
            SELECT Id, QuoteNumber, QuoteAccountId FROM Quote
            WHERE Name = :WORKSPACE_NAME AND NF_Channel__c = null
            ORDER BY CreatedDate ASC LIMIT 1
        ];
        if (qs.isEmpty()) {
            throw new NF_JourneyModels.JourneyException('The cart is not available right now. Please try again later.');
        }
        workspaceCache = new Draft();
        workspaceCache.quoteId = qs[0].Id;
        workspaceCache.quoteNumber = qs[0].QuoteNumber;
        workspaceCache.accountId = qs[0].QuoteAccountId;
        return workspaceCache;
    }

    /** The account + quote header the customer confirms into (first confirmation only). */
    private static Draft newDraft(NF_JourneyModels.CartRequest cart, NF_JourneyModels.ServiceabilityResult svc,
                                  NF_JourneyModels.JourneyContext ctx) {
        Id accountId = resolveAccount(cart, svc, ctx);
        NF_JourneyModels.Address a = svc.address;
        NF_JourneyModels.Technology primary = svc.technologies.isEmpty() ? null : svc.technologies[0];
        String street = String.isBlank(a.unit) ? a.street : a.street + '\n' + a.unit;
        Map<String, Object> placed = NF_RevCloudApi.post(PATH_PLACE, new Map<String, Object>{
            'pricingPref' => 'Skip',
            'configurationPref' => new Map<String, Object>{ 'configurationMethod' => 'Skip' },
            'graph' => new Map<String, Object>{ 'graphId' => 'nfQuoteHeader', 'records' => new List<Object>{
                new Map<String, Object>{ 'referenceId' => 'refQuote', 'record' => new Map<String, Object>{
                    'attributes' => new Map<String, Object>{ 'type' => 'Quote', 'method' => 'POST' },
                    'Name' => ('NovaFiber - ' + a.singleLine()).left(80),
                    'Pricebook2Id' => pricebookId(),
                    'QuoteAccountId' => accountId,
                    // The org trigger QuoteLineItemAfterAll copies Quote.StartDate onto every line;
                    // without it the lines lose their dates and the order can't be created.
                    'StartDate' => String.valueOf(Date.today()),
                    'ExpirationDate' => String.valueOf(Date.today().addDays(30)),
                    'NF_Channel__c' => ctx.channel,
                    'NF_ServiceabilityRef__c' => svc.serviceabilityId } },
                new Map<String, Object>{ 'referenceId' => 'refRecipient', 'record' => new Map<String, Object>{
                    'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineItemRecipient', 'method' => 'POST' },
                    'QuoteId' => '@{refQuote.id}',
                    'Name' => ('Service Location - ' + a.singleLine()).left(80),
                    'RecipientType' => 'Location',
                    'ServiceStreet' => street,
                    'ServiceCity' => a.city,
                    'ServiceState' => a.state,
                    'ServicePostalCode' => a.postalCode,
                    'ServiceCountry' => a.country,
                    'ServiceAddrValidationResult' => 'Success',
                    'ServiceabilityCheckDate' => DateTime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
                    'ServiceabilityData' => JSON.serialize(svc.technologies),
                    'MaxDownloadSpeed' => primary == null ? null : primary.maxDownloadMbps + ' Mbps',
                    'MaxUploadSpeed' => primary == null ? null : primary.maxUploadMbps + ' Mbps' } }
            } }
        }, 'Place Sales Transaction · Quote + service location');
        assertPlaced(placed, ctx);

        Draft d = loadDraft((Id) String.valueOf(placed.get('salesTransactionId')));
        if (d == null || d.recipientId == null) {
            throw new NF_JourneyModels.JourneyException('We could not save your quote right now. Please try again.');
        }
        return d;
    }

    /** Confirming again updates the journey's own quote; customers only ever touch prospect quotes. */
    private static Draft reusableDraft(NF_JourneyModels.CartRequest cart, NF_JourneyModels.JourneyContext ctx) {
        Id quoteId = toQuoteId(cart.quoteId);
        if (quoteId == null) return null;
        List<Quote> qs = [
            SELECT Id, Name, Status, QuoteAccountId, QuoteAccount.Name, NF_Channel__c
            FROM Quote WHERE Id = :quoteId LIMIT 1
        ];
        if (qs.isEmpty()) return null;
        Quote q = qs[0];
        Boolean ok = q.Status == 'Draft' && q.NF_Channel__c != null && q.Name != WORKSPACE_NAME
            && (ctx.isAgent || (q.QuoteAccount?.Name ?? '').startsWith(PROSPECT_PREFIX))
            && (String.isBlank(cart.accountId) || cart.accountId == q.QuoteAccountId)
            && [SELECT COUNT() FROM Order WHERE QuoteId = :q.Id] == 0;
        return ok ? loadDraft(q.Id) : null;
    }

    private static Draft loadDraft(Id quoteId) {
        List<Quote> qs = [
            SELECT Id, QuoteNumber, QuoteAccountId,
                   (SELECT Id FROM QuoteLineItemRecipients ORDER BY CreatedDate ASC LIMIT 1)
            FROM Quote WHERE Id = :quoteId LIMIT 1
        ];
        if (qs.isEmpty()) return null;
        Draft d = new Draft();
        d.quoteId = qs[0].Id;
        d.quoteNumber = qs[0].QuoteNumber;
        d.accountId = qs[0].QuoteAccountId;
        d.recipientId = qs[0].QuoteLineItemRecipients.isEmpty() ? null : qs[0].QuoteLineItemRecipients[0].Id;
        return d;
    }

    /** Removes the lines of a quote being re-confirmed (relationships cascade). */
    private static void replaceLines(Draft draft) {
        List<String> ids = new List<String>();
        for (QuoteLineItem li : [SELECT Id FROM QuoteLineItem WHERE QuoteId = :draft.quoteId LIMIT 200]) ids.add(li.Id);
        if (ids.isEmpty()) return;
        NF_RevCloudApi.del('/composite/sobjects?allOrNone=true&ids=' + String.join(ids, ','),
            'Remove ' + ids.size() + ' previous line(s) from Quote ' + draft.quoteNumber);
        for (String id : ids) NF_Trace.rec('DELETE', 'QuoteLineItem', id, 'replaced by the new confirmation');
    }

    /** The confirmed cart as quote lines: Revenue Cloud runs configuration rules and pricing on them. */
    private static void placeLines(Draft draft, NF_JourneyModels.CartRequest cart, Map<String, NF_JourneyModels.Offer> offers,
                                   NF_JourneyModels.JourneyContext ctx) {
        String today = String.valueOf(Date.today());
        List<Object> records = new List<Object>{
            new Map<String, Object>{ 'referenceId' => draft.quoteId, 'record' => new Map<String, Object>{
                'attributes' => new Map<String, Object>{ 'type' => 'Quote', 'method' => 'PATCH', 'id' => draft.quoteId },
                'StartDate' => today } }   // line dates follow the quote (org trigger QuoteLineItemAfterAll)
        };
        Integer n = 0;
        Integer lineCount = 0;
        for (NF_JourneyModels.CartItem item : cart.items) {
            n++;
            NF_JourneyModels.Offer offer = offers.get(item.productId);
            String parentRef = 'refL' + n;
            records.add(lineRecord(draft, parentRef, item.productId, offer.priceBookEntryId, offer.sellingModelType,
                item.quantity, item.discountPercent, today));
            lineCount++;
            Integer m = 0;
            for (NF_JourneyModels.Option op : optionsFor(offer, item).values()) {
                m++;
                String childRef = parentRef + 'c' + m;
                records.add(lineRecord(draft, childRef, op.productId, op.priceBookEntryId, op.sellingModelType,
                    quantityOf(item, op), item.discountPercent, today));
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
        Map<String, Object> placed = NF_RevCloudApi.post(PATH_PLACE, new Map<String, Object>{
            'pricingPref' => 'System',
            'configurationPref' => new Map<String, Object>{
                'configurationMethod' => 'System',
                'configurationOptions' => new Map<String, Object>{
                    'validateProductCatalog' => true, 'executeConfigurationRules' => true, 'addDefaultConfiguration' => false }
            },
            'graph' => new Map<String, Object>{ 'graphId' => 'nfQuoteLines', 'records' => records }
        }, 'Place Sales Transaction · ' + lineCount + ' line(s) on Quote ' + draft.quoteNumber + ' · rules + pricing');
        assertPlaced(placed, ctx);
    }

    private static Map<String, Object> lineRecord(Draft draft, String ref, String productId, String pbeId,
            String sellingModelType, Integer qty, Decimal discount, String today) {
        Map<String, Object> r = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineItem', 'method' => 'POST' },
            'QuoteId' => draft.quoteId,
            'Product2Id' => productId,
            'PricebookEntryId' => pbeId,
            'Quantity' => qty,
            'StartDate' => today,
            'PeriodBoundary' => 'Anniversary',
            'QuoteLineItemRecipientId' => draft.recipientId   // a real id: the org pricing pre-hook can't resolve @{refs}
        };
        if (sellingModelType != 'OneTime') r.put('BillingFrequency', 'Monthly');
        if (discount != null && discount > 0) r.put('Discount', discount);
        return new Map<String, Object>{ 'referenceId' => ref, 'record' => r };
    }

    private static Id resolveAccount(NF_JourneyModels.CartRequest cart, NF_JourneyModels.ServiceabilityResult svc,
                                     NF_JourneyModels.JourneyContext ctx) {
        if (String.isNotBlank(cart.accountId)) {
            if (ctx.canSelectAccount != true) throw new NF_JourneyModels.JourneyException('Selecting an account is not allowed.');
            List<Account> accs = [SELECT Id FROM Account WHERE Id = :cart.accountId WITH USER_MODE LIMIT 1];
            if (accs.isEmpty()) throw new NF_JourneyModels.JourneyException('The selected customer account was not found.');
            return accs[0].Id;
        }
        NF_JourneyModels.Address a = svc.address;
        String street = String.isBlank(a.unit) ? a.street : a.street + '\n' + a.unit;
        // REST, not DML: more Revenue Cloud callouts follow in this transaction.
        Map<String, Object> res = NF_RevCloudApi.post('/sobjects/Account', new Map<String, Object>{
            'Name' => PROSPECT_PREFIX + ' - ' + a.postalCode + ' - ' + DateTime.now().format('yyMMdd-HHmmss'),
            'BillingStreet' => street, 'BillingCity' => a.city, 'BillingState' => a.state,
            'BillingPostalCode' => a.postalCode, 'BillingCountry' => a.country,
            'ShippingStreet' => street, 'ShippingCity' => a.city, 'ShippingState' => a.state,
            'ShippingPostalCode' => a.postalCode, 'ShippingCountry' => a.country,
            'AccountSource' => ctx.isAgent ? 'Phone Inquiry' : 'Web'
        }, 'Create prospect account (sObject REST)',
            // Prospects legitimately share addresses (households re-quoting).
            new Map<String, String>{ 'Sforce-Duplicate-Rule-Header' => 'allowSave=true' });
        if (res.get('id') == null) {
            throw new NF_JourneyModels.JourneyException('We could not save your quote right now. Please try again.');
        }
        return (Id) String.valueOf(res.get('id'));
    }

    /** Prospects legitimately share addresses (households re-quoting); don't let duplicate rules block the journey. */
    public static Database.DMLOptions allowDuplicates() {
        Database.DMLOptions o = new Database.DMLOptions();
        o.DuplicateRuleHeader.allowSave = true;
        o.DuplicateRuleHeader.runAsCurrentUser = true;
        o.optAllOrNone = true;
        return o;
    }

    public static Id pricebookId() {
        if (Test.isRunningTest()) return Test.getStandardPricebookId();
        return [SELECT Id FROM Pricebook2 WHERE IsStandard = true AND IsActive = true LIMIT 1].Id;
    }

    private static void assertPlaced(Map<String, Object> placed, NF_JourneyModels.JourneyContext ctx) {
        if (placed.get('isSuccess') == true && placed.get('salesTransactionId') != null) return;
        String detail = NF_RevCloudApi.firstError(placed.get('errorResponse'));
        System.debug(LoggingLevel.ERROR, 'NF place sales transaction failed: ' + detail);
        throw new NF_JourneyModels.JourneyException('We could not save your quote right now. '
            + (ctx.isAgent ? detail : 'Please try again.'));
    }

    // ── Configurator (workspace sessions) ────────────────────────────────────

    private class Session {
        String contextId;
        Map<String, Object> response;
        Map<String, String> itemKeyByNode = new Map<String, String>();
        List<String> nodeOrder = new List<String>();
        Map<String, NF_JourneyModels.CartItem> itemByRoot = new Map<String, NF_JourneyModels.CartItem>();
        Map<String, NF_JourneyModels.Offer> offers;
        List<String> sessionLineIds;
    }

    private static Map<String, Object> configuratorOptions() {
        return new Map<String, Object>{
            'executePricing' => true,
            'executeConfigurationRules' => true,
            'addDefaultConfiguration' => false,   // the cart says exactly which options exist
            'validateProductCatalog' => true
        };
    }

    private static Map<String, Object> open(Draft ws) {
        Map<String, Object> opened = NF_RevCloudApi.post(PATH_CONFIGURE, new Map<String, Object>{
            'transactionId' => ws.quoteId,
            'configuratorOptions' => configuratorOptions(),
            'contextResponseType' => 'Full'
        }, 'Configurator · open session on the shared workspace');
        assertConfigured(opened);
        return opened;
    }

    /**
     * Replaces the session's lines with the cart in one configure call. Reuses the browser's session
     * while it is alive (Context Service TTL), otherwise opens a new one on the workspace.
     */
    private static Session configure(Draft ws, NF_JourneyModels.CartRequest cart, Map<String, NF_JourneyModels.Offer> offers) {
        if (cart.contextId != null && Pattern.matches('[A-Za-z0-9]{10,120}', cart.contextId) && cart.lineIds != null
                && cart.lineIds.size() <= 200) {
            try {
                return apply(ws, cart, offers, cart.contextId, cart.lineIds, 'your session');
            } catch (Exception e) {
                // Expired session or stale lines (e.g. a newer sync already replaced them): start over.
                NF_Trace.note('RULE', 'Configurator session not reusable', e.getMessage().left(200));
            }
        }
        Map<String, Object> opened = open(ws);
        List<String> existing = new List<String>();
        for (Map<String, Object> line : lines(opened)) existing.add(String.valueOf(line.get('id')));
        return apply(ws, cart, offers, String.valueOf(opened.get('transactionContextId')), existing, 'new session');
    }

    private static Session apply(Draft ws, NF_JourneyModels.CartRequest cart, Map<String, NF_JourneyModels.Offer> offers,
                                 String contextId, List<String> replaceLineIds, String sessionLabel) {
        Session s = new Session();
        s.contextId = contextId;
        s.offers = offers;
        List<Object> deleted = new List<Object>();
        for (String lineId : replaceLineIds) {
            deleted.add(new Map<String, Object>{ 'path' => new List<Object>{ ws.quoteId, lineId } });
        }
        List<Object> added = new List<Object>();
        String today = String.valueOf(Date.today());
        // Node ids are unique per sync: a configure call that deletes "x" and adds "x" ends up with neither.
        String generation = String.valueOf(Math.abs(Crypto.getRandomInteger())).left(6) + 'i';
        Integer n = 0;
        for (NF_JourneyModels.CartItem item : cart.items) {
            n++;
            NF_JourneyModels.Offer offer = offers.get(item.productId);
            String nodeId = NODE_PREFIX + generation + n;
            s.itemKeyByNode.put(nodeId, item.key);
            s.itemByRoot.put(nodeId, item);
            s.nodeOrder.add(nodeId);
            added.add(node(ws, nodeId, item.productId, offer.priceBookEntryId, offer.productSellingModelId,
                offer.sellingModelType, item.quantity, item.discountPercent, today));
            Integer m = 0;
            for (NF_JourneyModels.Option op : optionsFor(offer, item).values()) {
                m++;
                String childId = nodeId + 'c' + m;
                s.itemKeyByNode.put(childId, item.key);
                s.nodeOrder.add(childId);
                added.add(node(ws, childId, op.productId, op.priceBookEntryId, op.productSellingModelId,
                    op.sellingModelType, quantityOf(item, op), item.discountPercent, today));
                added.add(new Map<String, Object>{
                    'path' => new List<Object>{ ws.quoteId, childId, childId + 'r' },
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
        Map<String, Object> body = new Map<String, Object>{
            'transactionId' => ws.quoteId,
            'transactionContextId' => s.contextId,
            'configuratorOptions' => configuratorOptions(),
            'contextResponseType' => 'Full',
            'addedNodes' => added
        };
        if (!deleted.isEmpty()) body.put('deletedNodes', deleted);
        s.response = NF_RevCloudApi.post(PATH_CONFIGURE, body,
            'Configurator · ' + sessionLabel + ' · ' + cart.items.size() + ' item(s), ' + added.size() + ' node(s) added'
            + (deleted.isEmpty() ? '' : ', ' + deleted.size() + ' replaced') + ' · rules + pricing');
        assertConfigured(s.response);
        return s;
    }

    private static Map<String, Object> node(Draft ws, String id, String productId, String pbeId, String psmId,
            String sellingModelType, Integer qty, Decimal discount, String today) {
        Map<String, Object> o = new Map<String, Object>{
            'businessObjectType' => 'QuoteLineItem',
            'id' => id,
            'SalesTransactionItemSource' => id,
            'SalesTransactionItemParent' => ws.quoteId,
            'Product' => productId,
            'PricebookEntry' => pbeId,
            'ProductSellingModel' => psmId,
            'Quantity' => qty,
            'StartDate' => today,
            'PeriodBoundary' => 'Anniversary'
        };
        if (sellingModelType != 'OneTime') o.put('BillingFrequency', 'Monthly');
        if (discount != null && discount > 0) o.put('Discount', discount);
        return new Map<String, Object>{ 'path' => new List<Object>{ ws.quoteId, id }, 'addedObject' => o };
    }

    private static void assertConfigured(Map<String, Object> res) {
        if (res.get('success') != false) return;
        String detail = NF_RevCloudApi.firstError(res.get('errors'));
        System.debug(LoggingLevel.ERROR, 'NF configurator failed: ' + detail);
        throw new NF_JourneyModels.JourneyException('We could not update your cart right now: ' + detail);
    }

    private static List<Map<String, Object>> lines(Map<String, Object> res) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        Map<String, Object> tc = asMap(res.get('transactionContext'));
        for (Object st : asList(tc.get('SalesTransaction'))) {
            for (Object li : asList(asMap(st).get('SalesTransactionItem'))) {
                if (li instanceof Map<String, Object>) out.add((Map<String, Object>) li);
            }
        }
        return out;
    }

    private static NF_JourneyModels.QuoteSummary emptySummary() {
        NF_JourneyModels.QuoteSummary sum = new NF_JourneyModels.QuoteSummary();
        sum.status = 'Cart';
        sum.isSaved = false;
        sum.monthlyTotal = 0;
        sum.oneTimeTotal = 0;
        sum.monthlySavings = 0;
        sum.lines = new List<NF_JourneyModels.QuoteLine>();
        sum.messages = new List<NF_JourneyModels.CartMessage>();
        sum.hasErrors = false;
        return sum;
    }

    /** Live cart from the configurator context: priced lines, totals and messages per cart item. */
    private static NF_JourneyModels.QuoteSummary fromContext(Session s) {
        NF_JourneyModels.QuoteSummary sum = emptySummary();
        sum.contextId = s.contextId;

        List<Map<String, Object>> all = lines(s.response);
        Map<String, Map<String, Object>> byNode = new Map<String, Map<String, Object>>();
        for (Map<String, Object> li : all) byNode.put(String.valueOf(li.get('id')), li);
        // CML rules may have added lines (engine ids) or removed ours: follow what Revenue Cloud left.
        NF_ConfigRules.Result rules = NF_ConfigRules.read(all, s.response.get('uiTreatments'), s.itemByRoot, s.offers);
        sum.ruleAdjustments = rules.adjustments;
        sum.hiddenOptions = rules.hidden;
        List<String> order = new List<String>();
        for (String nodeId : s.nodeOrder) if (byNode.containsKey(nodeId)) order.add(nodeId);
        for (String lineId : rules.rootByLine.keySet()) if (!s.itemKeyByNode.containsKey(lineId)) order.add(lineId);
        s.sessionLineIds = new List<String>(byNode.keySet());
        Map<String, String> productNames = new Map<String, String>();
        for (String nodeId : order) {
            Map<String, Object> li = byNode.get(nodeId);
            NF_JourneyModels.QuoteLine l = new NF_JourneyModels.QuoteLine();
            l.itemKey = s.itemKeyByNode.containsKey(nodeId) ? s.itemKeyByNode.get(nodeId)
                : s.itemKeyByNode.get(rules.rootByLine.get(nodeId));
            l.lineId = nodeId;
            l.parentLineId = rules.parentByLine.get(nodeId);
            l.productId = str(li, 'Product');
            l.productName = str(li, 'ProductName');
            productNames.put(nodeId, l.productName);
            l.quantity = dec(li, 'Quantity');
            l.listPrice = dec(li, 'ListPrice');
            l.discountPercent = dec(li, 'Discount');
            l.netTotal = dec(li, 'NetTotalPrice');
            l.chargeType = str(li, 'SellingModelType') == 'OneTime' ? 'One-Time' : 'Monthly';
            sum.lines.add(l);
            Decimal net = l.netTotal == null ? 0 : l.netTotal.setScale(2, RoundingMode.HALF_UP);
            if (l.chargeType == 'One-Time') {
                sum.oneTimeTotal += net;
            } else {
                sum.monthlyTotal += net;
                Decimal gross = (l.listPrice == null ? 0 : l.listPrice) * (l.quantity == null ? 0 : l.quantity);
                sum.monthlySavings += gross - net;
            }
        }

        Map<String, Object> msgs = asMap(s.response.get('messages'));
        for (String nodeId : msgs.keySet()) {
            String rootNode = nodeId.startsWith(NODE_PREFIX) ? nodeId.replaceAll('c\\d+r?$', '') : null;
            for (Object o : asList(msgs.get(nodeId))) {
                Map<String, Object> m = asMap(o);
                NF_JourneyModels.CartMessage cm = new NF_JourneyModels.CartMessage();
                cm.itemKey = rootNode == null ? null : s.itemKeyByNode.get(rootNode);
                cm.productName = rootNode == null ? null : productNames.get(rootNode);
                cm.severity = str(m, 'messageType') == null ? 'info' : str(m, 'messageType').toLowerCase();
                cm.category = str(m, 'category');
                cm.message = str(m, 'message');
                sum.messages.add(cm);
                sum.hasErrors |= cm.severity == 'error';
            }
        }
        sum.messages = NF_ConfigRules.withoutStale(sum.messages, rules);
        for (NF_JourneyModels.CartMessage note : rules.notes) sum.messages.add(note);
        sum.hasErrors = false;
        for (NF_JourneyModels.CartMessage m : sum.messages) sum.hasErrors |= m.severity == 'error';
        NF_Trace.Entry t = NF_Trace.note('RULE', 'Configurator rules & bundle validation',
            sum.messages.isEmpty() ? 'no messages' : sum.messages.size() + ' message(s)');
        if (t != null) t.responseJson = NF_Trace.toJson(sum.messages);
        return sum;
    }

    // ── Summary of the saved quote ───────────────────────────────────────────

    public static NF_JourneyModels.QuoteSummary summarize(Id quoteId) {
        Quote q = [SELECT Id, QuoteNumber, Status, QuoteAccountId FROM Quote WHERE Id = :quoteId];
        NF_JourneyModels.QuoteSummary s = new NF_JourneyModels.QuoteSummary();
        s.quoteId = q.Id;
        s.quoteNumber = q.QuoteNumber;
        s.status = q.Status;
        s.accountId = q.QuoteAccountId;
        s.lines = new List<NF_JourneyModels.QuoteLine>();
        s.monthlyTotal = 0;
        s.oneTimeTotal = 0;
        s.monthlySavings = 0;

        Map<Id, Id> parentByChild = new Map<Id, Id>();
        for (QuoteLineRelationship rel : [
            SELECT MainQuoteLineId, AssociatedQuoteLineId FROM QuoteLineRelationship WHERE MainQuoteLine.QuoteId = :quoteId
        ]) parentByChild.put(rel.AssociatedQuoteLineId, rel.MainQuoteLineId);

        List<QuoteLineItem> priced = [
            SELECT Id, Product2Id, Product2.Name, Quantity, UnitPrice, Discount, TotalPrice, NetTotalPrice, SellingModelType
            FROM QuoteLineItem WHERE QuoteId = :quoteId ORDER BY LineNumber ASC
        ];
        if (NF_Trace.isEnabled()) {
            NF_Trace.Entry t = NF_Trace.note('SOQL', 'Saved quote lines', priced.size() + ' rows · Quote ' + q.QuoteNumber);
            t.responseJson = NF_Trace.toJson(priced);
        }
        for (QuoteLineItem li : priced) {
            NF_JourneyModels.QuoteLine l = new NF_JourneyModels.QuoteLine();
            l.lineId = li.Id;
            l.parentLineId = parentByChild.get(li.Id);
            l.productId = li.Product2Id;
            l.productName = li.Product2.Name;
            l.quantity = li.Quantity;
            l.listPrice = li.UnitPrice;
            l.discountPercent = li.Discount;
            l.netTotal = li.NetTotalPrice != null ? li.NetTotalPrice : li.TotalPrice;
            l.chargeType = li.SellingModelType == 'OneTime' ? 'One-Time' : 'Monthly';
            s.lines.add(l);
            Decimal gross = (li.UnitPrice == null ? 0 : li.UnitPrice) * (li.Quantity == null ? 0 : li.Quantity);
            Decimal net = l.netTotal == null ? 0 : l.netTotal.setScale(2, RoundingMode.HALF_UP);
            if (l.chargeType == 'One-Time') {
                s.oneTimeTotal += net;
            } else {
                s.monthlyTotal += net;
                s.monthlySavings += gross - net;
            }
        }
        return s;
    }

    // ── JSON helpers ─────────────────────────────────────────────────────────

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
