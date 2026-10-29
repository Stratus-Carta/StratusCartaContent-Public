/**
 * NF_AgentActionBookInstall
 * Agentforce action of the NovaFiber sales agent (NF_Sales_Agent): Books (or moves) the installation visit of the placed order in the chosen arrival window: work order, service appointment and install crew in Field Service.
 * Runs as the agent user; the work is done by NF_AgentJourney on the chat's journey.
 */
public without sharing class NF_AgentActionBookInstall {

    public class Request {
        @InvocableVariable(required=true label='Journey Key' description='The chat journey key.')
        public String journeyKey;
        @InvocableVariable(required=true label='Slot Key' description='Slot key of the chosen window, from get_install_slots.')
        public String slotKey;
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

    @InvocableMethod(label='NovaFiber: Book Install' description='Books (or moves) the installation visit of the placed order in the chosen arrival window: work order, service appointment and install crew in Field Service.' category='NovaFiber')
    public static List<Result> run(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request req : requests) {
            out.add(toResult(NF_AgentJourney.execute(req.journeyKey, 'book_install', new Op(req))));
        }
        return out;
    }

    private class Op implements NF_AgentJourney.Op {
        Request req;
        Op(Request req) { this.req = req; }
        public String run(NF_AgentJourney.Journey j) { return NF_AgentJourney.bookInstall(j, req.slotKey); }
    }
}
