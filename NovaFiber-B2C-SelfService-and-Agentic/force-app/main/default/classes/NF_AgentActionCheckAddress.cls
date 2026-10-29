/**
 * NF_AgentActionCheckAddress
 * Agentforce action of the NovaFiber sales agent (NF_Sales_Agent): Checks which NovaFiber services (fiber, copper, 5G home internet, TV) are available at a US address. Run before showing plans or building a cart.
 * Runs as the agent user; the work is done by NF_AgentJourney on the chat's journey.
 */
public without sharing class NF_AgentActionCheckAddress {

    public class Request {
        @InvocableVariable(required=true label='Journey Key' description='The chat journey key.')
        public String journeyKey;
        @InvocableVariable(required=true label='Street' description='Street address, e.g. 350 Main St.')
        public String street;
        @InvocableVariable(label='Unit' description='Apartment or unit, if any.')
        public String unit;
        @InvocableVariable(required=true label='City')
        public String city;
        @InvocableVariable(required=true label='State' description='2-letter US state code, e.g. NY.')
        public String state;
        @InvocableVariable(required=true label='ZIP Code' description='5-digit ZIP code.')
        public String postalCode;
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

    @InvocableMethod(label='NovaFiber: Check Address' description='Checks which NovaFiber services (fiber, copper, 5G home internet, TV) are available at a US address. Run before showing plans or building a cart.' callout=true category='NovaFiber')
    public static List<Result> run(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request req : requests) {
            NF_JourneyModels.Address a = new NF_JourneyModels.Address();
            a.street = req.street;
            a.unit = req.unit;
            a.city = req.city;
            a.state = req.state;
            a.postalCode = req.postalCode;
            out.add(toResult(NF_AgentJourney.execute(req.journeyKey, 'check_address', new Op(a))));
        }
        return out;
    }

    private class Op implements NF_AgentJourney.Op {
        NF_JourneyModels.Address address;
        Op(NF_JourneyModels.Address address) { this.address = address; }
        public String run(NF_AgentJourney.Journey j) { return NF_AgentJourney.checkAddress(j, address); }
    }
}