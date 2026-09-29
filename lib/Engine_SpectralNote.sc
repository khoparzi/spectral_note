// Engine_SpectralNote.sc
// 8-Band Spectral Envelope Follower for Monome Norns

Engine_SpectralNote : CroneEngine {
    var <synth;
    var <ampBusL, <ampBusR;
    var defaultAtk, defaultDcy, defaultGain;
    var numBands = 8;
    var oscForwarder;

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        var matronAddr;

        defaultAtk = Array.fill(numBands, { arg i; (0.015 - (i * 0.0016)).max(0.001) });
        defaultDcy = Array.fill(numBands, { arg i; (0.18 - (i * 0.02)).max(0.01) });
        defaultGain = [1.0, 1.0, 0.7, 0.6, 0.6, 0.7, 1.0, 1.0];

        ampBusL = Bus.control(context.server, 1);
        ampBusR = Bus.control(context.server, 1);

        // Matron (Norns Lua) listens on localhost port 10111
        matronAddr = NetAddr("127.0.0.1", 10111);

        SynthDef(\bandSplitterSynth, {
            arg inBus = 0, outBus = 0, masterGain = 2.0,
                ampBusL = 0, ampBusR = 0;
            var inSig, monoSig, envs;
            var bandFreqs = Array.geom(8, 60, 2.2);

            var atks  = \atk.kr(defaultAtk);
            var dcys  = \dcy.kr(defaultDcy);
            var gains = \gains.kr(defaultGain);

            inSig = SoundIn.ar([0, 1]);
            monoSig = (inSig[0] + inSig[1]) * 0.5 * masterGain;

            // Stereo In Amplitude for Page 1 Meters
            Out.kr(ampBusL, Amplitude.kr(inSig[0], 0.01, 0.1));
            Out.kr(ampBusR, Amplitude.kr(inSig[1], 0.01, 0.1));

            // 8-Band Filtering and Peak Follower Detection
            envs = bandFreqs.collect { |f, i|
                var band = BPF.ar(monoSig * gains[i], f.clip(20, 18000), 0.35);
                var detected = PeakFollower.ar(band, 0.999);
                var smoothed = LagUD.kr(A2K.kr(detected), atks[i], dcys[i]);
                (smoothed * 4.0).clip(0.0, 1.0).pow(0.8);
            };

            // SendReply to sclang
            SendReply.kr(Impulse.kr(30), '/fftAmps', envs);

            // Pass-through to output bus
            Out.ar(outBus, inSig);
        }).add;

        context.server.sync;

        // Bridge OSC from scsynth to Matron (port 10111)
        oscForwarder = OSCFunc({ arg msg;
            // msg format: [ '/fftAmps', nodeID, replyID, val0, val1, ... val7 ]
            // Forward only the 8 values to Lua
            matronAddr.sendMsg('/bandAmps', *msg[3..10]);
        }, '/fftAmps', context.server.addr);

        synth = Synth.new(\bandSplitterSynth, [
            \inBus, context.in_b,
            \outBus, context.out_b,
            \masterGain, 2.0,
            \ampBusL, ampBusL,
            \ampBusR, ampBusR,
            \atk, defaultAtk,
            \dcy, defaultDcy,
            \gains, defaultGain
        ], context.xg);

        // Norns Engine Commands
        this.addCommand("setMasterGain", "f", { arg msg;
            synth.set(\masterGain, msg[1]);
        });

        this.addCommand("setAtk", "if", { arg msg;
            var idx = (msg[1] - 1).clip(0, 7);
            defaultAtk[idx] = msg[2];
            synth.set(\atk, defaultAtk);
        });

        this.addCommand("setDcy", "if", { arg msg;
            var idx = (msg[1] - 1).clip(0, 7);
            defaultDcy[idx] = msg[2];
            synth.set(\dcy, defaultDcy);
        });

        this.addCommand("setBandGain", "if", { arg msg;
            var idx = (msg[1] - 1).clip(0, 7);
            defaultGain[idx] = msg[2];
            synth.set(\gains, defaultGain);
        });

        this.addPoll("sc_amp_l", { ampBusL.getSynchronous; });
        this.addPoll("sc_amp_r", { ampBusR.getSynchronous; });
    }

    free {
        oscForwarder.free;
        synth.free;
        ampBusL.free;
        ampBusR.free;
    }
}