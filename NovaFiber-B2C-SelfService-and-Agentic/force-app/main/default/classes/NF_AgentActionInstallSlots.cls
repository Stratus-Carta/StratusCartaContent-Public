/**
 * NF_AgentActionInstallSlots
 * Agentforce action of the NovaFiber sales agent (NF_Sales_Agent): Lists free installation arrival windows for the placed order from the Field Service crew calendars of the customer\'s area, optionally from a date and for the morning or afternoon.
 * Runs as the agent user; the work is done by NF_AgentJourney on the chat's journey.
 */
public without sharing class NF_AgentActionInstallSlots {

    public class Request {
        @InvocableVariable(required=true label='Journey Key' description='The chat journey key.')
        public String journeyKey;
        @InvocableVariable(label='From Date' description='Optional earliest date, yyyy-MM-dd.')
        public String fromDate;
        @InvocableVariable(label='Part Of Day' description='Optional: morning or afternoon.')
        public String partOfDay;
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

    @InvocableMethod(label='NovaFiber: Get Install Slots' description='Lists free installation arrival windows for the placed order from the Field Service crew calendars of the customer\'s area, optionally from a date and for the morning or afternoon.' category='NovaFiber')
    public static List<Result> run(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request req : requests) {
            out.add(toResult(NF_AgentJourney.execute(req.journeyKey, 'get_install_slots', new Op(req))));
        }
        return out;
    }

    private class Op implements NF_AgentJourney.Op {
        Request req;
        Op(Request req) { this.req = req; }
        public String run(NF_AgentJourney.Journey j) { return NF_AgentJourney.installSlots(j, req.fromDate, req.partOfDay); }
    }
}
