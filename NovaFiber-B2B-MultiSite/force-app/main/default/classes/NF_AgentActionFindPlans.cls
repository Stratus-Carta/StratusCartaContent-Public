/**
 * NF_AgentActionFindPlans
 * Agentforce action of the NovaFiber sales agent (NF_Sales_Agent): Lists the plans Revenue Cloud qualifies for the checked address (internet, TV, mobile), with plan codes, monthly prices, speeds, included equipment and optional add-ons.
 * Runs as the agent user; the work is done by NF_AgentJourney on the chat's journey.
 */
public without sharing class NF_AgentActionFindPlans {

    public class Request {
        @InvocableVariable(required=true label='Journey Key' description='The chat journey key.')
        public String journeyKey;
        @InvocableVariable(label='Category' description='Optional: internet, fiber, copper, 5G, TV or mobile. Empty for all.')
        public String category;
        @InvocableVariable(label='Max Monthly Price' description='Optional budget per month in USD.')
        public Decimal maxMonthlyPrice;
        @InvocableVariable(label='Min Download Mbps' description='Optional minimum download speed in Mbps.')
        public Decimal minDownloadMbps;
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

    @InvocableMethod(label='NovaFiber: Find Plans' description='Lists the plans Revenue Cloud qualifies for the checked address (internet, TV, mobile), with plan codes, monthly prices, speeds, included equipment and optional add-ons.' callout=true category='NovaFiber')
    public static List<Result> run(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request req : requests) {
            out.add(toResult(NF_AgentJourney.execute(req.journeyKey, 'find_plans',
                new Op(req.category, req.maxMonthlyPrice, req.minDownloadMbps))));
        }
        return out;
    }

    private class Op implements NF_AgentJourney.Op {
        String category;
        Decimal maxPrice;
        Decimal minSpeed;
        Op(String category, Decimal maxPrice, Decimal minSpeed) { this.category = category; this.maxPrice = maxPrice; this.minSpeed = minSpeed; }
        public String run(NF_AgentJourney.Journey j) { return NF_AgentJourney.findPlans(j, category, maxPrice, minSpeed); }
    }
}