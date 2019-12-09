require "spec_helper"

describe Sidekiq::Statsd::ServerMiddleware do
  subject(:middleware) { described_class.new }

  let(:worker) { double "Dummy worker" }
  let(:msg)    { { 'queue' => 'mailer' } }
  let(:queue)  { nil }
  let(:client) { double(::Statsd).as_null_object }

  let(:worker_name) { worker.class.name.gsub("::", ".") }

  let(:clean_job)  { ->{} }
  let(:broken_job) { ->{ raise 'error' } }

  before do
    allow_any_instance_of(::Statsd).to receive(:batch).and_yield(client)
  end

  it "doesn't initialize a ::Statsd client if passed-in" do
    expect(::Statsd)
      .to receive(:new)
      .never

    described_class.new(statsd: client)
  end

  context "with customised options" do
    describe "#new" do
      it "uses the custom statsd host and port" do
        expect(::Statsd)
          .to receive(:new)
          .with('example.com', 8126)
          .once

        described_class.new(host: 'example.com', port: 8126)
      end

      it "uses the custom metric name prefix options" do
        expect(client)
          .to receive(:time)
          .with("development.application.sidekiq.#{worker_name}.processing_time")
          .once
          .and_yield

        described_class
          .new(env: 'development', prefix: 'application.sidekiq')
          .call(worker, msg, queue, &clean_job)
      end
    end
  end

  context 'without global sidekiq stats' do
    let(:sidekiq_stats) { double }

    it "doesn't initialze a Sidekiq::Stats instance" do
      # Sidekiq::Stats.new calls fetch_stats!, which makes redis calls
      expect(described_class.new(sidekiq_stats: false).instance_variable_get(:@sidekiq_stats))
        .to be_nil
    end

    it "doesn't gauge sidekiq stats" do
      allow(Sidekiq::Stats).to receive(:new) { sidekiq_stats }

      expect(sidekiq_stats).not_to receive(:enqueued)
      expect(sidekiq_stats).not_to receive(:retry_size)
      expect(sidekiq_stats).not_to receive(:processed)
      expect(sidekiq_stats).not_to receive(:failed)

      described_class
        .new(sidekiq_stats: false)
        .call(worker, msg, queue, &clean_job)
    end
  end

  context "with successful execution" do
    let(:job) { clean_job }

    describe "#call" do
      it "increments success counter" do
        expect(client)
          .to receive(:increment)
          .with("production.worker.#{worker_name}.success")
          .once

        middleware.call(worker, msg, queue, &job)
      end

      it "times the process execution" do
        expect(client)
          .to receive(:time)
          .with("production.worker.#{worker_name}.processing_time")
          .once
          .and_yield

        middleware.call(worker, msg, queue, &job)
      end
    end

    it_behaves_like "a resilient gauge reporter"
  end

  context "with failed execution" do
    let(:job) { broken_job }

    describe "#call" do
      before do
        allow(client)
          .to receive(:time)
          .with("production.worker.#{worker_name}.processing_time")
          .and_yield
      end

      it "increments failure counter" do
        expect(client)
          .to receive(:increment)
          .with("production.worker.#{worker_name}.failure")
          .once

        expect{ middleware.call(worker, msg, queue, &job) }.to raise_error('error')
      end
    end

    it_behaves_like "a resilient gauge reporter"
  end
end
