module Bosh::Cli::TaskTracking
  class EventLogRenderer < TaskLogRenderer
    class InvalidEvent < StandardError; end

    class Task
      attr_accessor :name
      attr_accessor :progress
      attr_accessor :start_time
      attr_accessor :finish_time

      def initialize(name)
        @name = name
        @progress = 0
        @start_time = nil
        @finish_time = nil
      end
    end

    attr_reader :current_stage
    attr_reader :events_count
    attr_reader :started_at, :finished_at

    def initialize(options={})
      @lock = Monitor.new
      @events_count = 0
      @seen_stages = Set.new
      @out = Bosh::Cli::Config.output || $stdout
      @out.sync = true
      @buffer = StringIO.new
      @progress_bars = {}
      @pos = 0
      @time_adjustment = 0
      @stages_without_progress_bar = options[:stages_without_progress_bar] || []
    end

    def add_output(output)
      output.to_s.split("\n").each { |line| add_event(line) }
    end

    def add_event(event_line)
      event = parse_event(event_line)

      @lock.synchronize do
        # Handling the special "error" event
        if event["error"]
          done_with_stage if @current_stage
          add_error(event)
          return
        end

        if can_handle_event_without_progress_bar?(event)
          if @current_stage
            done_with_stage
            @current_stage = nil
            @buffer.print "\n"
          end
          handle_event_without_progress_bar(event)
          return
        end

        # One way to handle old stages is to prevent them
        # from appearing on screen altogether. That means
        # that we can always render the current stage only
        # and that simplifies housekeeping around progress
        # bars and messages. However we could always support
        # resuming the older stages rendering if we feel
        # that it's valuable.

        tags = event["tags"].is_a?(Array) ? event["tags"] : []
        stage_header = event["stage"]

        if tags.size > 0
          stage_header += " " + tags.sort.join(", ").make_green
        end

        unless @seen_stages.include?(stage_header)
          done_with_stage if @current_stage
          begin_stage(event, stage_header)
        end

        if @current_stage == stage_header
          append_event(event)
        end
      end

    rescue InvalidEvent => e
      # Swallow for the moment
    end

    def begin_stage(event, header)
      @current_stage = header
      @seen_stages << @current_stage

      @stage_start_time = Time.at(event["time"]) rescue Time.now
      @local_start_time = adjusted_time(@stage_start_time)

      @tasks = {}
      @done_tasks = []

      @eta = nil
      @stage_has_error = false # Error flag
      # Tracks max_in_flight best guess
      @tasks_batch_size = 0
      @batches_count = 0

      # Running average of task completion time
      @running_avg = 0

      append_stage_header
    end

    def render
      @lock.synchronize do
        @buffer.seek(@pos)
        output = @buffer.read
        @out.print output
        @pos = @buffer.tell
        output
      end
    end

    def add_error(event)
      error = event["error"] || {}
      code = error["code"]
      message = error["message"]

      error = "Error"
      error += " #{code}" if code
      error += ": #{message}" if message

      @buffer.puts("\n" + error.make_red)
    end

    def refresh
      # This is primarily used to refresh timer
      # without advancing rendering buffer
      @lock.synchronize do
        if @in_progress
          progress_bar.label = time_with_eta(Time.now - @local_start_time, @eta)
          progress_bar.refresh
        end
        render
      end
    end

    def finish(state)
      return if @events_count == 0

      @lock.synchronize do
        @done = true
        done_with_stage(state)
        render
      end
    end

    def duration_known?
      @started_at && @finished_at
    end

    def duration
      return unless duration_known?
      @finished_at - @started_at
    end

    private

    def append_stage_header
      @buffer.print "\n#{@current_stage}\n"
    end

    def done_with_stage(state = nil)
      return unless @in_progress

      if @last_event
        completion_time = Time.at(@last_event["time"]) rescue Time.now
      else
        completion_time = Time.now
      end

      if state.nil?
        state = @stage_has_error ? "error" : "done"
      end

      case state.to_s
      when "done"
        progress_bar.title = "Done".make_green
        progress_bar.finished_steps = progress_bar.total
      when "error"
        progress_bar.title = "Error".make_red
      else
        progress_bar.title = "Not done".make_yellow
      end

      progress_bar.bar_visible = false
      progress_bar.label = format_time(completion_time - @stage_start_time)
      progress_bar.refresh
      @buffer.print "\n"
      @in_progress = false
    end

    def progress_bar
      @progress_bars[@current_stage] ||= StageProgressBar.new(@buffer)
    end

    # We have to trust the first event in each stage
    # to have correct "total" and "current" fields.
    def append_event(event)
      validate_event(event)

      progress = 0
      total = event["total"].to_i

      if event["state"] == "started"
        task = Task.new(event["task"])
      else
        task = @tasks[event["index"]]
      end

      event_data = event["data"] || {}
      # Ignoring out-of-order events
      return if task.nil?

      @events_count += 1
      @last_event = event

      case event["state"]
      when "started"
        begin
          task.start_time = Time.at(event["time"])
          # Treat first "started" event as task start time
          @started_at = task.start_time if @started_at.nil?
        rescue
          task.start_time = Time.now
        end

        task.progress = 0

        @tasks[event["index"]] = task

        if @tasks.size > @tasks_batch_size
          # Heuristics here: we assume that local maximum of
          # tasks number is a "max_in_flight" value and batches count
          # should only be recalculated once we refresh this maximum.
          # It's unlikely that the first task in a batch will be finished
          # before the last one is started so @done_tasks is expected
          # to only have canaries.
          @tasks_batch_size = @tasks.size
          @non_canary_event_start_time = task.start_time
          @batches_count = ((total - @done_tasks.size) / @tasks_batch_size.to_f).ceil
        end

      when "finished", "failed"
        @tasks.delete(event["index"])
        @done_tasks << task

        begin
          task.finish_time = @finished_at = Time.at(event["time"])
        rescue
          task.finish_time = Time.now
        end

        task_time = task.finish_time - task.start_time

        n_done_tasks = @done_tasks.size.to_f
        @running_avg = @running_avg * (n_done_tasks - 1) / n_done_tasks + task_time.to_f / n_done_tasks

        progress = 1
        progress_bar.finished_steps += 1
        progress_bar.label = time_with_eta(task_time, @eta)
        progress_bar.clear_line

        task_name = task.name.to_s
        if task_name !~ /^[A-Z]{2}/
          task_name = task_name[0..0].to_s.downcase + task_name[1..-1].to_s
        end

        if event["state"] == "failed"
          status = [task_name.make_red, event_data["error"]].compact.join(": ")
          @stage_has_error = true
        else
          status = task_name.make_yellow
        end
        @buffer.puts("  #{status} (#{format_time(task_time)})")

      when "in_progress"
        progress = [event["progress"].to_f / 100, 1].min
      end

      if @batches_count > 0 && @non_canary_event_start_time
        @eta = adjusted_time(@non_canary_event_start_time + @running_avg * @batches_count)
      end

      progress_bar_gain = progress - task.progress
      task.progress = progress

      progress_bar.total = total
      progress_bar.title = @tasks.values.map { |t| t.name }.sort.join(", ")

      progress_bar.current += progress_bar_gain
      progress_bar.refresh

      @in_progress = true
    end

    def parse_event(event_line)
      event = JSON.parse(event_line)
      unless event.kind_of?(Hash)
        raise InvalidEvent, "Hash expected, #{event.class} given"
      end
      event
    rescue JSON::JSONError
      raise InvalidEvent, "Cannot parse event, invalid JSON"
    end

    def validate_event(event)
      unless event["time"] && event["stage"] && event["task"] &&
        event["index"] && event["total"] && event["state"]
        raise InvalidEvent, "Invalid event structure: stage, time, task, " +
                            "index, total, state are all required"
      end
    end

    def time_with_eta(time, eta)
      time_fmt = format_time(time)
      eta_fmt = eta && eta > Time.now ? format_time(eta - Time.now) : "--:--:--"
      "#{time_fmt}  ETA: #{eta_fmt}"
    end

    def adjusted_time(time)
      time + @time_adjustment.to_f
    end

    def can_handle_event_without_progress_bar?(event)
      @stages_without_progress_bar.include?(event["stage"])
    end

    def handle_event_without_progress_bar(event)
      event_header = "#{event["stage"].downcase}#{header_for_tags(event["tags"])}: #{event["task"]}"

      case event["state"]
        when "started"
          @buffer.print("  Started #{event_header}\n")
        when "finished"
          @buffer.print("     Done #{event_header}\n")
        when "failed"
          event_data = event["data"] || {}
          data_error = event_data["error"]
          error_msg = data_error ? ": #{data_error.make_red}" : ""
          @buffer.print("   Failed #{event_header}#{error_msg}\n")
      end
    end

    def header_for_tags(tags)
      tags = Array(tags)
      tags.size > 0 ? " " + tags.sort.join(", ").make_green : ""
    end
  end
end
