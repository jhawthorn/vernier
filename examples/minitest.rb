ENV["MT_CPU"] = "3"

require "minitest/autorun"

class TestMeme < Minitest::Test
  parallelize_me!

  def test_sleeping
    sleep 1
  end

  def test_also_sleeping
    sleep 1
  end

  def test_prime
    require "prime"
    assert_equal 1299709, Prime.first(100000).last
  end
end
