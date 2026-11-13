# frozen_string_literal: true

module Ferrum
  class Node
    #
    # Performs a drag and drop between two nodes of the same page with real
    # mouse input, see {Node#drag_to}.
    #
    class Drag
      # How often the drop point is recomputed and hit-tested while waiting
      # for the source or the target to become hittable.
      CHECK_DELAY = ENV.fetch("FERRUM_DRAG_CHECK_DELAY", 0.05).to_f
      # How many intermediate mousemove events a move to the drop point sends.
      MOVE_STEPS = ENV.fetch("FERRUM_DRAG_MOVE_STEPS", 10).to_i
      # How far the mouse moves right after the button press so that Chrome
      # crosses its drag threshold and fires `dragstart`.
      INIT_DISTANCE = 10

      # Computes the center of the node's visible area in root viewport
      # coordinates and whether a hit test there lands on the node or one of
      # its descendants, walking up same-origin frames. Returns
      # `[x, y, hittable]`, or `null` when the node has no visible area.
      POINT_SCRIPT = <<~JS
        function() {
          if (this.nodeType !== 1) {
            throw new Error("Cannot drag a non-element node");
          }
          const chain = [];
          let win = this.ownerDocument.defaultView;
          const rect = this.getBoundingClientRect();
          let left = rect.left;
          let top = rect.top;
          let right = rect.right;
          let bottom = rect.bottom;
          while (true) {
            left = Math.max(left, 0);
            top = Math.max(top, 0);
            right = Math.min(right, win.innerWidth);
            bottom = Math.min(bottom, win.innerHeight);
            chain.unshift(win);
            const frameElement = win.frameElement;
            if (!frameElement) {
              if (win !== win.parent) {
                throw new Error("Cannot drag a node inside a cross-origin frame");
              }
              break;
            }
            const frameRect = frameElement.getBoundingClientRect();
            const offsetX = frameRect.left + frameElement.clientLeft;
            const offsetY = frameRect.top + frameElement.clientTop;
            left = Math.max(left + offsetX, offsetX);
            top = Math.max(top + offsetY, offsetY);
            right = Math.min(right + offsetX, offsetX + frameElement.clientWidth);
            bottom = Math.min(bottom + offsetY, offsetY + frameElement.clientHeight);
            win = win.parent;
          }
          if (right <= left || bottom <= top) return null;
          const x = (left + right) / 2;
          const y = (top + bottom) / 2;
          let hit = null;
          let hitX = x;
          let hitY = y;
          for (let i = 0; i < chain.length; i++) {
            hit = chain[i].document.elementFromPoint(hitX, hitY);
            const next = chain[i + 1];
            if (!next) break;
            const frameElement = next.frameElement;
            if (hit !== frameElement) return [x, y, false];
            const frameRect = frameElement.getBoundingClientRect();
            hitX -= frameRect.left + frameElement.clientLeft;
            hitY -= frameRect.top + frameElement.clientTop;
          }
          return [x, y, hit === this || (hit !== null && this.contains(hit))];
        }
      JS
      private_constant :POINT_SCRIPT

      def initialize(source, target, timeout:)
        @source = source
        @target = target
        @timeout = timeout || source.page.timeout
        @page = source.page
      end

      def perform
        validate!
        button_down = false

        begin
          @source.scroll_into_view
          from = await_point(@source, "source")
          @page.mouse.move(x: from[0], y: from[1])
          @page.mouse.down
          button_down = true
          start_drag(from)
          # Scrolling before the drag session starts cancels it, and
          # scrolling the target into view can push the source out of the
          # viewport, so it happens only now, mid-drag.
          @target.scroll_into_view
          await_point(@target, "target") do |x, y|
            @page.mouse.move(x: x, y: y, steps: MOVE_STEPS)
          end
          @page.mouse.up
          button_down = false
        ensure
          cancel if button_down
        end
      end

      private

      def validate!
        raise ArgumentError, "target must be a Ferrum::Node, got #{@target.inspect}" unless @target.is_a?(Node)

        if @target.target_id != @source.target_id
          raise ArgumentError, "cannot drag to a node that belongs to another page"
        end

        if @page.keyboard.held_modifiers.positive?
          raise ArgumentError, "cannot drag while modifier keys are held, release them first"
        end

        return unless @page.mouse.pressed?

        raise ArgumentError, "cannot drag while a mouse button is pressed, release it first"
      end

      # Nudges the mouse a few pixels toward the horizontal center of the
      # viewport so Chrome crosses its drag threshold and fires `dragstart`,
      # opening the drag session before any scrolling happens.
      def start_drag(from)
        width = @page.evaluate("window.innerWidth")
        offset = from[0] < width / 2 ? INIT_DISTANCE : -INIT_DISTANCE
        @page.mouse.move(x: from[0] + offset, y: from[1], steps: MOVE_STEPS)
      end

      # Polls the node's visible point in root viewport coordinates until a
      # hit test there lands on the node, yielding each computed point so the
      # mouse can follow it. Raises DragTimeoutError when the node stays
      # invisible or covered past the timeout.
      def await_point(node, role)
        start = Utils::ElapsedTime.monotonic_time

        loop do
          x, y, hittable = node.evaluate(POINT_SCRIPT) || [nil, nil, false]
          if x
            yield(x, y) if block_given?
            return [x, y] if hittable
          else
            node.scroll_into_view
          end

          if Utils::ElapsedTime.timeout?(start, @timeout)
            raise DragTimeoutError,
                  "the drag #{role} stayed invisible or covered by another element for #{@timeout} seconds"
          end

          sleep(CHECK_DELAY)
        end
      end

      # Cancels an in-progress drag by releasing the button outside the
      # viewport, where no element can receive the drop. Escape doesn't
      # cancel a drag started through CDP input. Keys and buttons held
      # before the drag are left alone.
      def cancel
        @page.mouse.move(x: -1, y: -1)
      rescue Error
        # The browser is dead or the page navigated away, nothing to cancel.
      ensure
        release_button
      end

      def release_button
        @page.mouse.up
      rescue Error
        # The browser is dead or the page navigated away, nothing to release.
      end
    end
  end
end
