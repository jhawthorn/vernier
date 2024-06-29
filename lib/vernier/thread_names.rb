module Vernier
  # Collects names of all seen threads
  class ThreadNames
    def initialize
      @names = {}
      @tp = TracePoint.new(:thread_end) do |e|
        collect_thread(e.self)
      end
      @tp.enable
    end

    def [](object_id)
      @names[object_id] || "thread obj_id:#{object_id}"
    end

    def finish
      collect_running
      @tp.disable
    end

    private

    def collect_running
      Thread.list.each do |th|
        collect_thread(th)
      end
    end

    def collect_thread(th)
      @names[th.object_id] = pretty_name(th)
    end

    def pretty_name(thread)
      name = thread.name
      return name if name && !name.empty?

      if thread == Thread.main
        return $0
      end

      name = Thread.instance_method(:inspect).bind_call(thread)
      pretty = []
      best_id = name[/\#<Thread:0x\w+@?\s?(.*)\s+\S+>/, 1]
      if best_id
        Gem.path.each { |gem_dir| best_id.gsub!(gem_dir, "") }
        pretty << best_id unless best_id.empty?
      end
      pretty << "(#{thread.object_id})"
      pretty.join(' ')
    end
  end
end
