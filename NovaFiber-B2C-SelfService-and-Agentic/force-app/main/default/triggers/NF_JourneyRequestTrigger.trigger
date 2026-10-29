trigger NF_JourneyRequestTrigger on NF_Journey_Signal__e (after insert) {
    NF_JourneyWorker.process(Trigger.new);
}
