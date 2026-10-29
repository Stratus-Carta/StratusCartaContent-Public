/**
 * NF_AgentActionUpdateCart
 * Agentforce action of the NovaFiber sales agent (NF_Sales_Agent): Adds, updates or removes a plan in the cart (with add-ons) and has Revenue Cloud configure and price the cart. Returns the priced cart and any configuration rule messages.
 * Runs as the agent user; the work is done by NF_AgentJourney on the chat's journey.
 */
public without sharing class NF_AgentActionUpdateCart {

    public class Request {
        @InvocableVariable(required=true label='Journey Key' description='The chat journey key.')
        public String journeyKey;
        @InvocableVariable(required=true label='Operation' description='add, update, remove or clear.')
        public String operation;
        @InvocableVariable(label='Plan Code' description='Plan code from find_plans (or the exact plan name). Not needed for clear.')
        public String planCode;
        @InvocableVariable(label='Quantity' description='Optional number of this plan, 1-5 (e.g. mobile lines).')
        public Decimal quantity;
        @InvocableVariable(label='Add-ons To Add' description='Optional comma-separated add-on names to include, e.g. Mesh WiFi Extender, Professional Installation.')
        public String addAddOns;
        @InvocableVariable(label='Add-ons To Remove' description='Optional comma-separated add-on names to take out.')
        public String removeAddOns;
    }

    public class Result {
        @InvocableVariable(label='Success' description='False when the request could not be done; summary says why.')
        public Boolean success;
        @InvocableVariable(label='Summary' description='What happened, for the agent to explain to the customer.')
        public String summary;
        @InvocableVariable(label='Step' description='Journey step after the action: address, offers, cart, quote or done.')
        public String step;
    }

    private static Result toResult(NF_AgentJourney.Outcome o) {
        Result r = new Result();
        r.success = o.success;
        r.summary = o.summary;
        r.step = o.state == null ? null : NF_AgentJourney.step(o.state);
        return r;
    }

    @InvocableMethod(label='NovaFiber: Update Cart' description='Adds, updates or removes a plan in the cart (with add-ons) and has Revenue Cloud configure and price the cart. Returns the priced cart and any configuration rule messages.' callout=true category='NovaFiber')
    public static List<Result> run(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request req : requests) {
            out.add(toResult(NF_AgentJourney.execute(req.journeyKey, 'update_cart', new Op(req))));
        }
        return out;
    }

    private class Op implements NF_AgentJourney.Op {
        Request req;
        Op(Request req) { this.req = req; }
        public String run(NF_AgentJourney.Journey j) {
            return NF_AgentJourney.updateCart(j, req.operation, req.planCode, req.quantity, req.addAddOns, req.removeAddOns);
        }
    }
}