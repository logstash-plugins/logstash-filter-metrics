require "logstash/devutils/rspec/spec_helper"
require "logstash/filters/metrics"

describe LogStash::Filters::Metrics do

  context "with basic meter config" do
    context "when no events were received" do
      it "should not flush" do
        config = {"meter" => ["http_%{response}"]}
        filter = LogStash::Filters::Metrics.new config
        filter.register

        events = filter.flush
        insist { events }.nil?
      end
    end

    context "when events are received" do
      context "on the first flush" do
        subject {
          config = {"meter" => ["http_%{response}"]}
          filter = LogStash::Filters::Metrics.new config
          filter.register
          filter.filter LogStash::Event.new({"response" => 200})
          filter.filter LogStash::Event.new({"response" => 200})
          filter.filter LogStash::Event.new({"response" => 404})
          filter.flush
        }

        it "should flush counts" do
          insist { subject.length } == 1
          insist { subject.first.get("http_200")["count"] } == 2
          insist { subject.first.get("http_404")["count"] } == 1
        end

        it "should include rates and percentiles" do
          meters = [ "http_200", "http_404" ]
          rates = [ "rate_1m", "rate_5m", "rate_15m" ]
          meters.each do |meter|
            rates.each do |rate|
              insist { subject.first.get(meter) }.include? rate
            end
          end
        end
      end

      context "on the second flush" do
        it "should not reset counts" do
          config = {"meter" => ["http_%{response}"]}
          filter = LogStash::Filters::Metrics.new config
          filter.register
          filter.filter LogStash::Event.new({"response" => 200})
          filter.filter LogStash::Event.new({"response" => 200})
          filter.filter LogStash::Event.new({"response" => 404})

          events = filter.flush
          events = filter.flush
          insist { events.length } == 1
          insist { events.first.get("http_200")["count"] } == 2
          insist { events.first.get("http_404")["count"] } == 1
        end
      end

      context "[split_metrics] on the first flush" do
        subject {
          config = {"meter" => ["http_%{response}"], "split_metrics" => true}
          filter = LogStash::Filters::Metrics.new config
          filter.register
          filter.filter LogStash::Event.new({"response" => 200})
          filter.filter LogStash::Event.new({"response" => 200})
          filter.filter LogStash::Event.new({"response" => 404})
          filter.flush
        }

        it "should flush counts in separate messages" do
          insist { subject.length } == 2
          reject { subject.first.get("http_200") }.nil?
          insist { subject.first.get("http_200")["count"] } == 2
          reject { subject.last.get("http_404") }.nil?
          insist { subject.last.get("http_404")["count"] } == 1
        end

        def insist_metric_has_field(event, name, metrics)
          reject { event.get(name) }.nil?
          metrics.each do |metric|
            insist { event.get(name) }.include? metric
          end
        end

        it "should include rates and percentiles in separate messages" do
          insist { subject.length } == 2
          metrics = ["rate_1m", "rate_5m", "rate_15m"]
          insist_metric_has_field(subject.first, "http_200", metrics)
          insist_metric_has_field(subject.last, "http_404", metrics)
        end
      end
    end

    context "when custom rates and percentiles are selected" do
      context "on the first flush" do
        subject {
          config = {
            "meter" => ["http_%{response}"],
            "rates" => [1]
          }
          filter = LogStash::Filters::Metrics.new config
          filter.register
          filter.filter LogStash::Event.new({"response" => 200})
          filter.filter LogStash::Event.new({"response" => 200})
          filter.filter LogStash::Event.new({"response" => 404})
          filter.flush
        }

        it "should include only the requested rates" do
          rate_fields = subject.first.get("http_200").to_hash.keys.select {|field| field.start_with?("rate") }
          insist { rate_fields.length } == 1
          insist { rate_fields }.include? "rate_1m"
        end
      end
    end
  end

  context "with multiple instances" do
    it "counts should be independent" do
      config1 = {"meter" => ["http_%{response}"]}
      config2 = {"meter" => ["http_%{response}"]}
      filter1 = LogStash::Filters::Metrics.new config1
      filter2 = LogStash::Filters::Metrics.new config2
      events1 = [
        LogStash::Event.new({"response" => 200}),
        LogStash::Event.new({"response" => 404})
      ]
      events2 = [
        LogStash::Event.new({"response" => 200}),
        LogStash::Event.new({"response" => 200})
      ]
      filter1.register
      filter2.register

      events1.each do |event|
        filter1.filter event
      end

      events2.each do |event|
        filter2.filter event
      end

      events1 = filter1.flush
      events2 = filter2.flush

      insist { events1.first.get("http_200")["count"] } == 1
      insist { events2.first.get("http_200")["count"] } == 2
      insist { events1.first.get("http_404")["count"] } == 1
      insist { events2.first.get("http_404") } == nil
    end
  end

  context "with timer config" do
    context "on the first flush" do
      subject {
        config = {"timer" => ["http_request_time", "%{request_time}"]}
        filter = LogStash::Filters::Metrics.new config
        filter.register
        filter.filter LogStash::Event.new({"request_time" => 10})
        filter.filter LogStash::Event.new({"request_time" => 20})
        filter.filter LogStash::Event.new({"request_time" => 30})
        filter.flush
      }

      it "should flush counts" do
        insist { subject.length } == 1
        insist { subject.first.get("http_request_time")["count"] } == 3
      end

      it "should include rates and percentiles keys" do
        metrics = ["rate_1m", "rate_5m", "rate_15m", "p1", "p5", "p10", "p90", "p95", "p99"]
        metrics.each do |metric|
          insist { subject.first.get("http_request_time") }.include? metric
        end
      end

      it "should include min value" do
        insist { subject.first.get("http_request_time")['min'] } == 10.0
      end

      it "should include mean value" do
        insist { subject.first.get("http_request_time")['mean'] } == 20.0
      end

      it "should include stddev value" do
        insist { subject.first.get("http_request_time")['stddev'] } == Math.sqrt(10.0)
      end

      it "should include max value" do
        insist { subject.first.get("http_request_time")['max'] } == 30.0
      end

      it "should include percentile value" do
        insist { subject.first.get("http_request_time")['p99'] } == 30.0
      end
    end
  end

  context "when custom rates and percentiles are selected" do
    context "on the first flush" do
      subject {
        config = {
          "timer" => ["http_request_time", "request_time"],
          "rates" => [1],
          "percentiles" => [1, 2]
        }
        filter = LogStash::Filters::Metrics.new config
        filter.register
        filter.filter LogStash::Event.new({"request_time" => 1})
        filter.flush
      }

      it "should flush counts" do
        insist { subject.length } == 1
        insist { subject.first.get("http_request_time")["count"] } == 1
      end

      it "should include only the requested rates" do
        rate_fields = subject.first.get("http_request_time").to_hash.keys.select {|field| field.start_with?("rate") }
        insist { rate_fields.length } == 1
        insist { rate_fields }.include? "rate_1m"
      end

      it "should include only the requested percentiles" do
        percentile_fields = subject.first.get("http_request_time").to_hash.keys.select {|field| field.start_with?("p") }
        insist { percentile_fields.length } == 2
        insist { percentile_fields }.include? "p1"
        insist { percentile_fields }.include? "p2"
      end
    end
  end


  context "when a custom flush_interval is set" do
    it "should flush only when required" do
      config = {"meter" => ["http_%{response}"], "flush_interval" => 15}
      filter = LogStash::Filters::Metrics.new config
      filter.register
      filter.filter LogStash::Event.new({"response" => 200})

      insist { filter.flush }.nil?        # 5s
      insist { filter.flush }.nil?        # 10s
      insist { filter.flush.length } == 1 # 15s
      insist { filter.flush }.nil?        # 20s
      insist { filter.flush }.nil?        # 25s
      insist { filter.flush.length } == 1 # 30s
    end
  end

  context "when a custom clear_interval is set" do
    it "should clear the metrics after interval has passed" do
      config = {"meter" => ["http_%{response}"], "clear_interval" => 15}
      filter = LogStash::Filters::Metrics.new config
      filter.register
      filter.filter LogStash::Event.new({"response" => 200})

      insist { filter.flush.first.get("http_200")["count"] } == 1 # 5s
      insist { filter.flush.first.get("http_200")["count"] } == 1 # 10s
      insist { filter.flush.first.get("http_200")["count"] } == 1 # 15s
      insist { filter.flush }.nil?                         # 20s
    end
  end

  context "when invalid rates are set" do
    subject {
      config = {"meter" => ["http_%{response}"], "rates" => [90]}
      filter = LogStash::Filters::Metrics.new config
    }

    it "should raise an error" do
      insist {subject.register }.raises(LogStash::ConfigurationError)
    end
  end
end
