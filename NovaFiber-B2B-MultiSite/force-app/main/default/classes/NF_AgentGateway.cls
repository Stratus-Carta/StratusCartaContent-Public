/**
 * NF_AgentGateway
 * Website side of the AI journey. The nfAgentJourney chat talks to the NovaFiber sales agent
 * (NF_Sales_Agent) through the Agent API and gets back the agent's replies plus the journey its actions
 * built (address, qualified plans, configurator-priced cart, quote, order), shown as live cards.
 *
 * Runs without sharing so guest visitors can chat. A chat is only reachable with its journey key
 * (128-bit random, issued by startChat). Contact details go from the page form straight to the journey
 * (saveCustomer), never through the language model.
 * The agent's actions record their NF_Trace on the journey; it is shown inside the Agent API call.
 */
public without sharing class NF_AgentGateway {

    private static final Integer MAX_MESSAGE = 1000;

    public class CartItemView {
        public String key;
        public NF_JourneyModels.Offer offer;
        public Integer quantity;
        public Map<String, Integer> options = new Map<String, Integer>();
        public Decimal discountPercent;
    }

    public class View {
        public String journeyKey;
        public String journeyName;
        public List<String> replies = new List<String>();
        public String step;
        public NF_JourneyModels.ServiceabilityResult serviceability;
        public List<NF_JourneyModels.OfferCategory> offers;
        public List<CartItemView> cart = new List<CartItemView>();
        public NF_JourneyModels.QuoteSummary cartState;
        public NF_JourneyModels.QuoteSummary quote;
        public Boolean quoteCurrent = false;
        public Boolean customerCaptured = false;
        public NF_JourneyModels.OrderResult order;
        public NF_JourneyModels.InstallAppointment appointment;
        public String focus;                        // section the page brings into view (addons)
    }

    private interface Op {
        Object run();
    }

    // ── Entry points ─────────────────────────────────────────────────────────

    @AuraEnabled
    public static NF_JourneyModels.Envelope startChat(Boolean debug) {
        return execute('startChat', debug, new StartOp());
    }

    @AuraEnabled
    public static NF_JourneyModels.Envelope sendMessage(String journeyKey, String text, Boolean debug) {
        return execute('sendMessage', debug, new SendOp(journeyKey, text));
    }

    /** The secure checkout form: contact details go to the journey, not to the agent. */
    @AuraEnabled
    public static NF_JourneyModels.Envelope saveCustomer(String journeyKey, String customerJson, Boolean debug) {
        return execute('saveCustomer', debug, new CustomerOp(journeyKey, customerJson));
    }

    /** Ends the agent session; discard also deletes the journey's draft quote (unless it was ordered). */
    @AuraEnabled
    public static NF_JourneyModels.Envelope endChat(String journeyKey, Boolean discard, Boolean debug) {
        return execute('endChat', debug, new EndOp(journeyKey, discard == true));
    }

    // ── Operations ───────────────────────────────────────────────────────────

    private class StartOp implements Op {
        public Object run() {
            String key = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
            NF_AgentApi.Session s = NF_AgentApi.startSession(key);
            NF_Agent_Journey__c rec = new NF_Agent_Journey__c(Journey_Key__c = key, Session_Id__c = s.sessionId,
                Sequence__c = 0, Step__c = 'address', State__c = JSON.serialize(new NF_AgentJourney.State(), true));
            insert rec;
            NF_Trace.rec('INSERT', 'NF_Agent_Journey__c', rec.Id, 'chat journey');
            NF_AgentJourney.Journey j = new NF_AgentJourney.Journey();
            j.rec = [SELECT Id, Name, Journey_Key__c FROM NF_Agent_Journey__c WHERE Id = :rec.Id];
            j.state = new NF_AgentJourney.State();
            View v = view(j);
            v.replies = s.messages;
            return v;
        }
    }

    private class SendOp implements Op {
        String key;
        String text;
        SendOp(String key, String text) { this.key = key; this.text = text; }
        public Object run() {
            if (String.isBlank(text)) throw new NF_JourneyModels.JourneyException('Please type a message.');
            String message = text.trim().abbreviate(MAX_MESSAGE);
            NF_AgentJourney.Journey j = NF_AgentJourney.load(key);
            if (String.isBlank(j.rec.Session_Id__c)) throw new NF_JourneyModels.JourneyException('This chat has ended. Please start a new one.');
            Integer seq = (j.rec.Sequence__c == null ? 0 : j.rec.Sequence__c.intValue()) + 1;

            List<String> replies;
            try {
                replies = NF_AgentApi.send(j.rec.Session_Id__c, seq, message);
            } catch (NF_RevCloudApi.RevCloudException e) {
                System.debug(LoggingLevel.ERROR, 'NF agent message failed: ' + e.getMessage());
                throw new NF_JourneyModels.JourneyException('The assistant did not answer. Please try again.');
            }
            NF_Trace.Entry turn = NF_AgentApi.lastEntry;

            // What the agent's actions did during this turn (they ran as the agent user, in their own transactions).
            j = NF_AgentJourney.load(key);
            absorbActionTrace(NF_AgentJourney.pendingTrace(j.rec), turn);
            View v = view(j);
            v.replies = replies;
            v.focus = j.state.focus;
            if (j.state.focus != null) {   // shown once
                j.state.focus = null;
                j.rec.State__c = JSON.serialize(j.state, true);
            }
            j.rec.Sequence__c = seq;
            j.rec.Pending_Trace__c = null;
            update j.rec;
            return v;
        }
    }

    private class CustomerOp implements Op {
        String key;
        String payload;
        CustomerOp(String key, String payload) { this.key = key; this.payload = payload; }
        public Object run() {
            NF_JourneyModels.CustomerDetails c;
            try {
                c = (NF_JourneyModels.CustomerDetails) JSON.deserialize(payload, NF_JourneyModels.CustomerDetails.class);
            } catch (JSONException e) {
                throw new NF_JourneyModels.JourneyException('Please check your details and try again.');
            }
            NF_AgentJourney.Journey j = NF_AgentJourney.load(key);
            NF_AgentJourney.saveCustomer(j, c);
            NF_AgentJourney.save(j, null);
            NF_Trace.rec('UPDATE', 'NF_Agent_Journey__c', j.rec.Id, 'checkout details saved for the agent (not sent to the model)');
            return view(j);
        }
    }

    private class EndOp implements Op {
        String key;
        Boolean discard;
        EndOp(String key, Boolean discard) { this.key = key; this.discard = discard; }
        public Object run() {
            NF_AgentJourney.Journey j;
            try {
                j = NF_AgentJourney.load(key);
            } catch (NF_JourneyModels.JourneyException e) {
                return new Map<String, Object>{ 'ended' => true };   // already gone
            }
            if (String.isNotBlank(j.rec.Session_Id__c)) {
                try {
                    NF_AgentApi.endSession(j.rec.Session_Id__c);
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, 'NF agent session end failed: ' + e.getMessage());
                }
            }
            Boolean ordered = j.state.order != null;
            if (discard && !ordered) {
                NF_AgentJourney.discardQuote(j.state);
                delete j.rec;
                NF_Trace.rec('DELETE', 'NF_Agent_Journey__c', j.rec.Id, 'discarded chat journey');
            } else {
                j.rec.Session_Id__c = null;
                NF_AgentJourney.save(j, null);
            }
            return new Map<String, Object>{ 'ended' => true, 'discarded' => discard && !ordered };
        }
    }

    // ── View ─────────────────────────────────────────────────────────────────

    @TestVisible
    private static View view(NF_AgentJourney.Journey j) {
        NF_AgentJourney.State s = j.state;
        View v = new View();
        v.journeyKey = j.rec.Journey_Key__c;
        v.journeyName = j.rec.Name;
        v.step = NF_AgentJourney.step(s);
        v.serviceability = s.serviceability;
        v.quote = s.quote;
        v.quoteCurrent = s.quoteCurrent == true;
        v.customerCaptured = s.customer != null;
        v.order = s.order;
        v.appointment = s.appointment;
        v.cartState = s.priced;
        if (s.serviceability != null) {
            NF_JourneyCache.setMode(NF_JourneyCache.MODE_CACHED);
            v.offers = NF_OfferService.getOffers(s.serviceability);
            Map<String, NF_JourneyModels.Offer> byId = new Map<String, NF_JourneyModels.Offer>();
            for (NF_JourneyModels.OfferCategory c : v.offers) for (NF_JourneyModels.Offer o : c.offers) byId.put(o.productId, o);
            for (NF_JourneyModels.CartItem item : s.items) {
                CartItemView iv = new CartItemView();
                iv.key = item.key;
                iv.offer = byId.get(item.productId);
                iv.quantity = item.quantity;
                for (NF_JourneyModels.SelectedOption so : item.options) iv.options.put(so.componentId, so.quantity);
                if (iv.offer != null) v.cart.add(iv);
            }
        }
        return v;
    }

    /** Re-keys the actions' trace entries and nests their roots under the Agent API call of this turn. */
    @TestVisible
    private static void absorbActionTrace(List<NF_Trace.Entry> entries, NF_Trace.Entry turn) {
        if (entries == null || entries.isEmpty() || !NF_Trace.isEnabled()) return;
        Integer batch = 0;
        for (NF_Trace.Entry e : entries) {
            if (e.parentId == null) batch++;
            String prefix = 'a' + batch + '.';
            e.id = prefix + e.id;
            e.parentId = e.parentId == null ? turn?.id : prefix + e.parentId;
        }
        NF_Trace.absorb(entries);
    }

    // ── Envelope ─────────────────────────────────────────────────────────────

    private static NF_JourneyModels.Envelope execute(String name, Boolean debug, Op op) {
        Long started = DateTime.now().getTime();
        NF_JourneyModels.JourneyContext ctx = NF_JourneyController.getContext();
        Boolean tracing = ctx.isAgent || (debug == true && ctx.inspectorAllowed == true);
        if (tracing) NF_Trace.enable();
        NF_JourneyModels.Envelope env = new NF_JourneyModels.Envelope();
        NF_Trace.Entry root = NF_Trace.start('APEX', 'NF_AgentGateway.' + name + '()',
            'AI journey · ' + (ctx.isGuest ? 'guest' : UserInfo.getUserName()));
        try {
            env.dataJson = JSON.serialize(op.run());
            NF_Trace.end(root, 'OK', null);
        } catch (Exception e) {
            env.error = e instanceof NF_JourneyModels.JourneyException ? e.getMessage()
                : 'Something went wrong. Please try again.' + (ctx.isAgent ? ' (' + e.getTypeName() + ': ' + e.getMessage() + ')' : '');
            NF_Trace.end(root, 'ERROR', e.getTypeName() + ': ' + e.getMessage());
            if (!(e instanceof NF_JourneyModels.JourneyException)) {
                System.debug(LoggingLevel.ERROR, 'NF agent gateway error: ' + e.getTypeName() + ': ' + e.getMessage()
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
}
