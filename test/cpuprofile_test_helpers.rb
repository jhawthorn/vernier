# frozen_string_literal: true

module CpuprofileTestHelpers
  def assert_valid_cpuprofile(output)
    assert_kind_of(String, output)

    data = JSON.parse(output)
    assert_kind_of(Hash, data)

    required_fields = %w[nodes startTime endTime samples timeDeltas]
    required_fields.each do |field|
      assert_includes(data.keys, field, "Missing required field: #{field}")
    end

    assert_kind_of(Array, data["nodes"])
    assert_kind_of(Numeric, data["startTime"])
    assert_kind_of(Numeric, data["endTime"])
    assert_kind_of(Array, data["samples"])
    assert_kind_of(Array, data["timeDeltas"])

    assert_operator(data["nodes"].length, :>=, 1)
    assert_equal(data["samples"].length, data["timeDeltas"].length)

    data["samples"].each do |sample_id|
      assert(id_exists(data["nodes"], sample_id))
    end

    root_node = data["nodes"].first
    assert_equal(0, root_node["id"])
    assert_equal("(root)", root_node["callFrame"]["functionName"])
    assert_equal(-1, root_node["callFrame"]["lineNumber"])

    data["nodes"].each do |node|
      assert(node["id"])
      assert(node["callFrame"])
      assert(node["callFrame"]["functionName"])
      assert(node["callFrame"]["scriptId"])
      assert(node["callFrame"]["url"])
      assert(node["callFrame"]["lineNumber"])
      assert(node["callFrame"]["columnNumber"])
      assert(node["hitCount"])
      assert_kind_of(Array, node["children"])
      node["children"].each do |child|
        assert(id_exists(data["nodes"], child))
      end
    end
  end

  def id_exists(nodes, id)
    nodes.any? { |node| node["id"] == id }
  end
end
