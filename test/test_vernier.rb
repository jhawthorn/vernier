# frozen_string_literal: true

require "test_helper"

class TestVernier < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Vernier::VERSION
  end

  def test_that_forked_children_do_not_hang
    return skip
    1000.times do
      Vernier.trace do
        pid = Process.fork do
          sleep 0.1
          # noop
        end
        _, status = Process.waitpid2(pid)
        assert_predicate status, :success?
      end
      print "."
    end
  end
end
