def tarai(x, y, z) =
  x <= y ? y : tarai(tarai(x-1, y, z),
                     tarai(y-1, z, x),
                     tarai(z-1, x, y))

require 'vernier'
Vernier.trace(out: "ractor.json") do
  4.times.map do
    Ractor.new { tarai(14, 7, 0) }
  end.each(&:take)
end
