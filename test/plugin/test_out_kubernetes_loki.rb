require "helper"
require "fluent/plugin/out_kubernetes_loki.rb"

class KubernetesLokiOutputTest < Test::Unit::TestCase
  setup do
    Fluent::Test.setup
  end

  test "failure" do
    flunk
  end

  private

  def create_driver(conf)
    Fluent::Test::Driver::Output.new(Fluent::Plugin::KubernetesLokiOutput).configure(conf)
  end
end
