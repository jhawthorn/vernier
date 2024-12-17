# frozen_string_literal: true

require "test_helper"

class TestFork < Minitest::Test
  def test_that_forked_children_do_not_hang
    Vernier.trace do
      pid = Process.fork do
        sleep 0.1
        # noop
      end
      _, status = Process.waitpid2(pid)
      assert_predicate status, :success?
    end
  end
end
