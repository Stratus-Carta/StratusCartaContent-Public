/**
 * NF_JourneyController
 * Single @AuraEnabled entry point for the NovaFiber guided selling LWCs, used by
 * both the Experience Cloud self-service site (guest) and the internal agent app.
 *
 * Runs without sharing so guest visitors can read the catalog and create their own
 * prospect records. Every agent-only capability is enforced here (and re-checked in
 * the services) via the NF_Agent_Assisted_Selling custom permission — never by the UI.
 *
 * Every operation returns NF_JourneyModels.Envelope (payload JSON or a customer-safe error,
 * plus the NF_Trace for the Journey Inspector when the caller may see it).
 */
public without sharing class NF_JourneyController {

    @TestVisible private static final String AGENT_PERMISSION = 'NF_Agent_Assisted_Selling';
    @TestVisible private static final Decimal MAX_AGENT_DISCOUNT = 20;

    /** Tests set this because custom permissions deployed in the same transaction are not yet visible. */
    @TestVisible private static Boolean agentOverride;
    @TestVisible private static Boolean guestDebugOverride;

    private interface Op {
        Object run();
    }

    // ── Entry points ─────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static NF_JourneyModels.JourneyContext getContext() {
        return context();
    }

    @AuraEnabled
    public static NF_JourneyModels.Envelope getCatalogPreview(Boolean debug, String mode) {
        NF_JourneyCache.setMode(mode);
        return execute('getCatalogPreview', debug, new CatalogPreviewOp());
    }

    @AuraEnabled
    public static NF_JourneyModels.Envelope checkServiceability(String addressJson, Boolean debug, String mode) {
        NF_JourneyCache.setMode(mode);
        return execute('checkServiceability', debug, new CheckOp(addressJson));
    }

    @AuraEnabled
    public static NF_JourneyModels.Envelope overrideServiceability(String serviceabilityJson, Boolean debug) {
        return execute('overrideServiceability', debug, new OverrideOp(serviceabilityJson));
    }

    @AuraEnabled
    public static NF_JourneyModels.Envelope getOffers(String serviceabilityJson, Boolean debug, String mode) {
        NF_JourneyCache.setMode(mode);
        return execute('getOffers', debug, new OffersOp(serviceabilityJson));
    }

    /** Opens a configurator session ahead of the first cart change (called when the plans are shown). */
    @AuraEnabled
    public static NF_JourneyModels.Envelope startCart(Boolean debug, String mode) {
        NF_JourneyCache.setMode(mode);
        return execute('startCart', debug, new StartCartOp());
    }

    /** Every cart change: Revenue Cloud configurator session on the shared workspace (rules, pricing, messages). */
    @AuraEnabled
    public static NF_JourneyModels.Envelope syncCart(String cartJson, Boolean debug, String mode) {
        NF_JourneyCache.setMode(mode);
        return execute('syncCart', debug, new CartOp(cartJson, false));
    }

    /** "Get my quote": re-check the address, configure and save the lines on the quote. */
    @AuraEnabled
    public static NF_JourneyModels.Envelope priceCart(String cartJson, Boolean debug, String mode) {
        NF_JourneyCache.setMode(mode);
        return execute('priceCart', debug, new CartOp(cartJson, true));
    }

    /** Agents: invalidate every cached serviceability, catalog, offer and priced-cart entry. */
    @AuraEnabled
    public static NF_JourneyModels.Envelope flushJourneyCache(Boolean debug) {
        return execute('flushJourneyCache', debug, new FlushOp());
    }

    /** The visitor abandons the journey: delete its draft quote and prospect account. */
    @AuraEnabled
    public static NF_JourneyModels.Envelope discardJourney(String quoteId, Boolean debug) {
        return execute('discardJourney', debug, new DiscardOp(quoteId));
    }

    /** Polled by the LWC for guest requests handed to NF_JourneyWorker. */
    @AuraEnabled
    public static NF_JourneyModels.Envelope getRequestResult(String requestKey, Boolean debug) {
        return execute('getRequestResult', debug, new PollOp(requestKey));
    }

    @AuraEnabled
    public static NF_JourneyModels.Envelope submitOrder(String quoteId, String customerJson, Boolean debug) {
        return execute('submitOrder', debug, new SubmitOp(quoteId, customerJson));
    }

    @AuraEnabled
    public static NF_JourneyModels.Envelope searchAccounts(String term, Boolean debug) {
        return execute('searchAccounts', debug, new SearchOp(term));
    }

    // ── Installation booking (Field Service) ─────────────────────────────────

    /** The order's service locations and their booked appointments. */
    @AuraEnabled
    public static NF_JourneyModels.Envelope getInstallSites(String orderId, String bookingToken, Boolean debug) {
        return execute('getInstallSites', debug, new InstallOp('sites', orderId, bookingToken, null, null));
    }

    /** Free arrival windows for one site (crew calendars of its state's service territory). */
    @AuraEnabled
    public static NF_JourneyModels.Envelope getInstallSlots(String orderId, String bookingToken, String siteKey, Boolean debug) {
        return execute('getInstallSlots', debug, new InstallOp('slots', orderId, bookingToken, siteKey, null));
    }

    /** Work order + service appointment + assigned crew for the chosen window (or reschedule). */
    @AuraEnabled
    public static NF_JourneyModels.Envelope bookInstall(String orderId, String bookingToken, String siteKey, String slotKey, Boolean debug) {
        return execute('bookInstall', debug, new InstallOp('book', orderId, bookingToken, siteKey, slotKey));
    }

    // ── Agreements, proposals and e-signature ────────────────────────────────

    /** Generates the quote's service agreement (household) or proposal (business) from its Word template. */
    @AuraEnabled
    public static NF_JourneyModels.Envelope prepareAgreement(String quoteId, String signerJson, Boolean debug) {
        return execute('prepareAgreement', debug, new AgreementOp('prepare', quoteId, signerJson, null, null, null));
    }

    /** Polled while Document Generation renders the PDF. */
    @AuraEnabled
    public static NF_JourneyModels.Envelope getAgreement(String quoteId, String processId, Boolean debug) {
        return execute('getAgreement', debug, new AgreementOp('poll', quoteId, null, processId, null, null));
    }

    /** DocuSign embedded signing (or the sandbox signing pad when DocuSign is not configured). */
    @AuraEnabled
    public static NF_JourneyModels.Envelope startSigning(String quoteId, String signerJson, String returnUrl, String pageOrigin, Boolean debug) {
        return execute('startSigning', debug, new AgreementOp('start', quoteId, signerJson, returnUrl, pageOrigin, null));
    }

    /** The signer finished: verify with DocuSign (or check the typed signature) and keep the signed PDF. */
    @AuraEnabled
    public static NF_JourneyModels.Envelope completeSigning(String quoteId, String envelopeId, String signerJson, String typedSignature, Boolean debug) {
        return execute('completeSigning', debug, new AgreementOp('complete', quoteId, signerJson, envelopeId, null, typedSignature));
    }

    // ── Multi-site quoting (agents and site visitors) ────────────────────────

    /** Serviceability + qualified plans for up to 10 uploaded sites. */
    @AuraEnabled
    public static NF_JourneyModels.Envelope checkSites(String sitesJson, Boolean debug, String mode) {
        NF_JourneyCache.setMode(mode);
        return execute('checkSites', debug, new MultiSiteOp('check', sitesJson));
    }

    /** Browse-time location prices: products priced per state from LocationBasedDecisionTable, nothing saved. */
    @AuraEnabled
    public static NF_JourneyModels.Envelope getStatePrices(String requestJson, Boolean debug, String mode) {
        NF_JourneyCache.setMode(mode);
        return execute('getStatePrices', debug, new MultiSiteOp('prices', requestJson));
    }

    /** Every site's cart priced for its state (configurator, nothing saved). */
    @AuraEnabled
    public static NF_JourneyModels.Envelope priceSiteCarts(String sitesJson, Boolean debug, String mode) {
        NF_JourneyCache.setMode(mode);
        return execute('priceSiteCarts', debug, new MultiSiteOp('carts', sitesJson));
    }

    /** One quote: a service location recipient and line group per site, lines priced by their site's state. */
    @AuraEnabled
    public static NF_JourneyModels.Envelope saveMultiSiteQuote(String requestJson, Boolean debug, String mode) {
        NF_JourneyCache.setMode(mode);
        return execute('saveMultiSiteQuote', debug, new MultiSiteOp('save', requestJson));
    }

    // ── Operations ───────────────────────────────────────────────────────────

    private class CatalogPreviewOp implements Op {
        public Object run() {
            return NF_OfferService.getCatalogPreview();
        }
    }

    private class CheckOp implements Op {
        String payload;
        CheckOp(String payload) { this.payload = payload; }
        public Object run() {
            return NF_ServiceabilityService.check(
                (NF_JourneyModels.Address) JSON.deserialize(payload, NF_JourneyModels.Address.class));
        }
    }

    private class OverrideOp implements Op {
        String payload;
        OverrideOp(String payload) { this.payload = payload; }
        public Object run() {
            if (context().canOverrideServiceability != true) {
                throw new NF_JourneyModels.JourneyException('Serviceability override is not allowed.');
            }
            return NF_ServiceabilityService.overrideResult((NF_JourneyModels.ServiceabilityResult)
                JSON.deserialize(payload, NF_JourneyModels.ServiceabilityResult.class));
        }
    }

    private class OffersOp implements Op {
        String payload;
        OffersOp(String payload) { this.payload = payload; }
        public Object run() {
            return NF_OfferService.getOffers((NF_JourneyModels.ServiceabilityResult)
                JSON.deserialize(payload, NF_JourneyModels.ServiceabilityResult.class));
        }
    }

    private class CartOp implements Op {
        String payload;
        Boolean save;
        CartOp(String payload, Boolean save) { this.payload = payload; this.save = save; }
        public Object run() {
            NF_JourneyModels.CartRequest cart = (NF_JourneyModels.CartRequest)
                JSON.deserialize(payload, NF_JourneyModels.CartRequest.class);
            NF_JourneyModels.JourneyContext ctx = context();
            // Revenue Cloud REST calls run as the integration user, so guests are served synchronously too.
            return save ? NF_QuoteService.saveQuote(cart, ctx) : NF_QuoteService.syncCart(cart, ctx);
        }
    }

    private class MultiSiteOp implements Op {
        String action;
        String payload;
        MultiSiteOp(String action, String payload) { this.action = action; this.payload = payload; }
        public Object run() {
            NF_JourneyModels.JourneyContext ctx = context();
            // Agents and site visitors alike; what differs (account choice, site limit, prospect accounts) is in the service.
            if (action == 'check') {
                return NF_MultiSiteService.checkSites((List<NF_JourneyModels.SiteInput>)
                    JSON.deserialize(payload, List<NF_JourneyModels.SiteInput>.class));
            }
            if (action == 'prices') {
                return NF_MultiSiteService.statePrices((NF_JourneyModels.StatePriceRequest)
                    JSON.deserialize(payload, NF_JourneyModels.StatePriceRequest.class));
            }
            if (action == 'carts') {
                return NF_MultiSiteService.priceCarts((List<NF_JourneyModels.SiteCart>)
                    JSON.deserialize(payload, List<NF_JourneyModels.SiteCart>.class), ctx);
            }
            return NF_MultiSiteService.saveQuote((NF_JourneyModels.MultiSiteRequest)
                JSON.deserialize(payload, NF_JourneyModels.MultiSiteRequest.class), ctx);
        }
    }

    private class AgreementOp implements Op {
        String action;
        String quoteId;
        String signerJson;
        String arg;       // processId | returnUrl | envelopeId
        String origin;
        String typed;
        AgreementOp(String action, String quoteId, String signerJson, String arg, String origin, String typed) {
            this.action = action;
            this.quoteId = quoteId;
            this.signerJson = signerJson;
            this.arg = arg;
            this.origin = origin;
            this.typed = typed;
        }
        public Object run() {
            NF_JourneyModels.JourneyContext ctx = context();
            NF_JourneyModels.CustomerDetails signer = String.isBlank(signerJson) ? null
                : (NF_JourneyModels.CustomerDetails) JSON.deserialize(signerJson, NF_JourneyModels.CustomerDetails.class);
            if (signer != null) signer.portalPassword = null;   // never needed here
            if (action == 'prepare') return NF_DocumentService.generate(quoteId, signer, ctx);
            if (action == 'poll') return NF_DocumentService.poll(quoteId, arg, ctx);
            if (action == 'start') return NF_ESignService.start(quoteId, signer, arg, origin, ctx);
            return NF_ESignService.complete(quoteId, arg, signer, typed, ctx);
        }
    }

    private class InstallOp implements Op {
        String action;
        String orderId;
        String token;
        String siteKey;
        String slotKey;
        InstallOp(String action, String orderId, String token, String siteKey, String slotKey) {
            this.action = action;
            this.orderId = orderId;
            this.token = token;
            this.siteKey = siteKey;
            this.slotKey = slotKey;
        }
        public Object run() {
            NF_JourneyModels.JourneyContext ctx = context();
            if (action == 'sites') return NF_SchedulingService.sites(orderId, token, ctx);
            if (action == 'slots') return NF_SchedulingService.slots(orderId, token, siteKey, ctx);
            return NF_SchedulingService.book(orderId, token, siteKey, slotKey, ctx);
        }
    }

    private class FlushOp implements Op {
        public Object run() {
            if (context().canFlushCache != true) {
                throw new NF_JourneyModels.JourneyException('Flushing the journey cache is not allowed.');
            }
            Integer generation = NF_JourneyCache.flush();
            NF_Trace.note('CACHE', 'Journey cache flushed', 'generation ' + generation + ' · every cached entry is now stale');
            return new Map<String, Object>{ 'generation' => generation };
        }
    }

    private class StartCartOp implements Op {
        public Object run() {
            return NF_QuoteService.openSession();
        }
    }

    private class DiscardOp implements Op {
        String quoteId;
        DiscardOp(String quoteId) { this.quoteId = quoteId; }
        public Object run() {
            return NF_QuoteService.discard(quoteId, context());
        }
    }

    private class PollOp implements Op {
        String key;
        PollOp(String key) { this.key = key; }
        public Object run() {
            return NF_JourneyWorker.poll(key);
        }
    }

    private class SubmitOp implements Op {
        String quoteId;
        String payload;
        SubmitOp(String quoteId, String payload) { this.quoteId = quoteId; this.payload = payload; }
        public Object run() {
            NF_JourneyModels.CustomerDetails c = (NF_JourneyModels.CustomerDetails)
                JSON.deserialize(payload, NF_JourneyModels.CustomerDetails.class);
            // Revenue Cloud REST calls run as the integration user: guests are served synchronously too.
            return NF_OrderService.submit(quoteId, c, context());
        }
    }

    private class SearchOp implements Op {
        String term;
        SearchOp(String term) { this.term = term; }
        public Object run() {
            if (context().canSelectAccount != true) {
                throw new NF_JourneyModels.JourneyException('Account search is not allowed.');
            }
            List<NF_JourneyModels.AccountMatch> out = new List<NF_JourneyModels.AccountMatch>();
            if (String.isBlank(term) || term.trim().length() < 2) return out;
            String pattern = '%' + String.escapeSingleQuotes(term.trim()) + '%';
            List<Account> rows = [
                SELECT Id, Name, Phone, BillingStreet, BillingCity, BillingState, BillingPostalCode
                FROM Account
                WHERE (Name LIKE :pattern OR Phone LIKE :pattern) AND (NOT Name LIKE 'NovaFiber Prospect%')
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC LIMIT 10
            ];
            NF_Trace.dml('READ', rows, 'account search "' + term.trim() + '"');
            for (Account a : rows) {
                NF_JourneyModels.AccountMatch m = new NF_JourneyModels.AccountMatch();
                m.accountId = a.Id;
                m.name = a.Name;
                m.phone = a.Phone;
                m.billingAddress = String.join(new List<String>{
                    a.BillingStreet, a.BillingCity, a.BillingState, a.BillingPostalCode }, ' ').normalizeSpace();
                out.add(m);
            }
            return out;
        }
    }

    // ── Envelope ─────────────────────────────────────────────────────────────

    private static NF_JourneyModels.Envelope execute(String name, Boolean debug, Op op) {
        Long started = DateTime.now().getTime();
        NF_JourneyModels.JourneyContext ctx = context();
        Boolean tracing = ctx.isAgent || (debug == true && ctx.inspectorAllowed);
        if (tracing) NF_Trace.enable();

        NF_JourneyModels.Envelope env = new NF_JourneyModels.Envelope();
        NF_Trace.Entry root = NF_Trace.start('APEX', 'NF_JourneyController.' + name + '()',
            ctx.channel + (ctx.isGuest ? ' · guest' : ' · ' + UserInfo.getUserName()) + ' · ' + NF_JourneyCache.mode() + ' journey');
        try {
            Object data = op.run();
            env.dataJson = JSON.serialize(data);
            NF_Trace.end(root, 'OK', null);
        } catch (Exception e) {
            env.error = safeMessage(e, ctx);
            NF_Trace.end(root, 'ERROR', e.getTypeName() + ': ' + e.getMessage()
                + (ctx.isAgent ? '\n' + e.getStackTraceString() : ''));
            if (!(e instanceof NF_JourneyModels.JourneyException)) {
                System.debug(LoggingLevel.ERROR, 'NF journey error: ' + e.getTypeName() + ': ' + e.getMessage()
                    + '\n' + e.getStackTraceString());
            }
        }
        if (tracing) {
            env.trace = NF_Trace.drain();
            env.limits = NF_Trace.limitsSnapshot();
        }
        env.serverMs = Integer.valueOf(DateTime.now().getTime() - started);
        return env;
    }

    private static String safeMessage(Exception e, NF_JourneyModels.JourneyContext ctx) {
        if (e instanceof NF_JourneyModels.JourneyException) return e.getMessage();
        String msg = 'Something went wrong. Please try again.';
        return ctx.isAgent ? msg + ' (' + e.getTypeName() + ': ' + e.getMessage() + ')' : msg;
    }

    @TestVisible
    private static NF_JourneyModels.JourneyContext context() {
        Boolean isGuest = Auth.CommunitiesUtil.isGuestUser();
        Boolean isAgent = agentOverride != null ? agentOverride
            : !isGuest && FeatureManagement.checkPermission(AGENT_PERMISSION);
        NF_JourneyModels.JourneyContext c = new NF_JourneyModels.JourneyContext();
        c.isAgent = isAgent;
        c.isGuest = isGuest;
        c.channel = isAgent ? NF_JourneyModels.CHANNEL_AGENT : NF_JourneyModels.CHANNEL_SELF_SERVICE;
        c.canDiscount = isAgent;
        c.maxDiscountPercent = isAgent ? MAX_AGENT_DISCOUNT : 0;
        c.canOverrideServiceability = isAgent;
        c.canSelectAccount = isAgent;
        c.userName = isAgent ? UserInfo.getName() : null;
        c.currencyIsoCode = UserInfo.getDefaultCurrency();
        c.inspectorAllowed = isAgent || guestDebugEnabled();
        c.journeyMode = NF_JourneyCache.defaultMode();
        c.canFlushCache = isAgent;
        return c;
    }

    private static Boolean guestDebugEnabled() {
        if (guestDebugOverride != null) return guestDebugOverride;
        NF_Journey_Setting__mdt s = NF_Journey_Setting__mdt.getInstance('Default');
        return s != null && s.Guest_Debug_Enabled__c == true;
    }
}
