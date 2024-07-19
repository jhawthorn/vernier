# frozen_string_literal: true

require "test_helper"

class TestVernier < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Vernier::VERSION
  end

  def test_that_forked_children_do_not_hang
    pid = Process.fork do
      # noop
    end
    _, status = Process.waitpid2(pid)
    assert_predicate status, :success?
  end
end
