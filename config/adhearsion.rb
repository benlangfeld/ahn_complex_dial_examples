# encoding: utf-8

Adhearsion.config do |config|
  config.platform.logging.level = :trace

  config.punchblock.platform = :xmpp
  config.punchblock.username = "usera@freeswitch.local-dev.mojolingo.com"
  config.punchblock.password = "1"
end

# TODO: This should move to Matrioska
module Matrioska::DialWithApps
  private

  def dial_with_local_apps(to, options = {}, &block)
    dial = Adhearsion::CallController::Dial::ParallelConfirmationDial.new to, options, call

    runner = Matrioska::AppRunner.new call
    yield runner, dial
    runner.start

    dial.track_originating_call
    dial.prep_calls
    dial.place_calls
    dial.await_completion
    dial.cleanup_calls
    dial.status
  end

  def dial_with_remote_apps(to, options = {}, &block)
    dial = Adhearsion::CallController::Dial::ParallelConfirmationDial.new to, options, call

    dial.track_originating_call

    dial.prep_calls do |new_call|
      new_call.on_joined call do
        runner = Matrioska::AppRunner.new new_call
        yield runner, dial
        runner.start
      end
    end

    dial.place_calls
    dial.await_completion
    dial.cleanup_calls
    dial.status
  end
end

class MidCallMenuController < Adhearsion::CallController
  include Matrioska::DialWithApps

  def run
    menu 'Press 1 to return to the call, 2 to transfer, or 3 to hang up on the other person.' do
      match(1) { main_dial.rejoin }
      match(2) { transfer }
      match(3) do
        main_dial.cleanup_calls
        say "Thanks. It seems we're all done. Goodbye."
      end

      timeout { say 'Sorry, you took too long' }
      invalid { say 'Sorry, that was an invalid choice' }
      failure { say 'Sorry, you failed to select a valid option' }
    end
  end

  private

  def transfer
    transfer_to = ask 'Please enter the number to transfer to. Once connected, press 1 to rejoin.', limit: 10
    speak "Transferring to #{transfer_to.response}"
    dial_with_local_apps "tel:#{transfer_to.response}" do |runner, dial|
      runner.map_app '1' do
        dial.skip_cleanup
        main_dial.merge dial
      end
    end
  end

  def main_dial
    metadata['current_dial']
  end
end

# TODO: Hold music should be natively supported in Adhearsion
class HoldMusicController < Adhearsion::CallController
  def run
    output = play! 'http://www.kamazoy.com/wp-content/uploads/2013/03/013.wav', repeat: 1000
    call.on_joined { output.stop! }
  end
end

class InboundController < Adhearsion::CallController
  include Matrioska::DialWithApps

  def run
    dial_with_remote_apps 'sip:5201996@localphone.com' do |runner, dial|
      runner.map_app '1' do
        logger.info "Splitting calls"
        blocker = Celluloid::Condition.new
        dial.split main: HoldMusicController, others: MidCallMenuController, others_callback: ->(call) { blocker.broadcast }
        blocker.wait # This prevents the Matrioska listener from starting again until the calls are rejoined
      end
    end
  end
end

Adhearsion.router do
  route 'dial', InboundController
end
