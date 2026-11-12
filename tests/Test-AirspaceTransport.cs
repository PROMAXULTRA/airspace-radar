using System;
using System.IO;
using System.Collections.Generic;

public static class AirspaceTransportTests {
    // A bounded receiver that refuses another write until its previous ACK was
    // read. This catches the original 115 KB burst even without physical USB.
    private sealed class BoundedLink : IAirspaceLink {
        private readonly byte[] expected;
        private readonly uint sequence;
        private readonly int payloadBytes;
        private readonly Queue<string> replies = new Queue<string>();
        private string currentAck;
        private bool header, waiting;
        public int BytesReceived, Writes, LargestBlock;
        public bool Committed, MissingReady, InvalidBlock, TransientTimeout = true;
        public int ErrorAtByte = -1;
        public BoundedLink(byte[] packet) {
            expected = packet;
            sequence = BitConverter.ToUInt32(packet, 8);
            payloadBytes = packet.Length - 16;
        }
        public void DiscardInput() { }
        public void Write(byte[] bytes, int offset, int count) {
            if (waiting) throw new Exception("Sender wrote before consuming the acknowledgement");
            Writes++;
            if (!header) {
                if (count != 16 || offset != 0) throw new Exception("Payload sent before header handshake");
                header = true; waiting = true;
                currentAck = "READY " + sequence + (InvalidBlock ? " 8192" : " 1024");
                replies.Enqueue("READY IPS2 240 240 RGB565LE"); // Boot banner is not a frame ACK.
                replies.Enqueue(currentAck);
                return;
            }
            if (count > 1024 || offset != 16 + BytesReceived) throw new Exception("Bounded receiver overflow or wrong offset");
            for (int i = 0; i < count; i++) if (bytes[offset+i] != expected[16+BytesReceived+i]) throw new Exception("Payload changed in transit");
            LargestBlock = Math.Max(LargestBlock, count); BytesReceived += count;
            waiting = true;
            if (ErrorAtByte >= 0 && BytesReceived >= ErrorAtByte) currentAck = "ERR TIMEOUT " + sequence + " " + BytesReceived + "/115200";
            else if (BytesReceived == payloadBytes) { replies.Enqueue("DRAW " + sequence + " 256 1 900"); currentAck = "OK " + sequence; Committed = true; }
            else currentAck = "CHUNK " + sequence + " " + BytesReceived;
            replies.Enqueue("CHUNK 999999 0"); // An unrelated ACK must not advance the stream.
            replies.Enqueue(currentAck);
        }
        public string ReadLine(int timeoutMs) {
            if (TransientTimeout) { TransientTimeout = false; throw new TimeoutException(); }
            if (MissingReady || replies.Count == 0) throw new TimeoutException();
            string reply = replies.Dequeue();
            if (reply == currentAck) waiting = false;
            return reply;
        }
    }

    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    private sealed class ProbeLink : IAirspaceLink {
        private readonly bool supported;
        private bool written, banner;
        public ProbeLink(bool supported) { this.supported = supported; }
        public void DiscardInput() { }
        public void Write(byte[] bytes, int offset, int count) {
            Check(!written && count == 4 && System.Text.Encoding.ASCII.GetString(bytes, offset, count) == "IPS?",
                "Capability probe must not send pixels or a scene payload");
            written = true;
        }
        public string ReadLine(int timeoutMs) {
            if (!banner) { banner = true; return "READY IPS2 240 240 RGB565LE"; }
            if (supported && written) return "CAP IPS4";
            throw new TimeoutException();
        }
    }

    public static void RunScene(byte[] packet) {
        Check(AirspaceTransport.SupportsScene(new ProbeLink(true), 100), "IPS4 capability was not detected");
        Check(!AirspaceTransport.SupportsScene(new ProbeLink(false), 20), "An IPS2 board was mistaken for IPS4");
        uint sequence = BitConverter.ToUInt32(packet, 8);
        BoundedLink link = new BoundedLink(packet);
        AirspaceTransport.Send(link, packet, sequence, 500);
        Check(link.Committed && link.BytesReceived == packet.Length - 16, "Scene packet was not completed");
        Check(link.Writes == 1 + (packet.Length - 16 + 1023) / 1024, "Scene packet block count is incorrect");
    }

    public static void Run(byte[] packet) {
        uint sequence = BitConverter.ToUInt32(packet,8);
        BoundedLink good = new BoundedLink(packet);
        AirspaceTransport.Send(good,packet,sequence,500);
        Check(good.Committed && good.BytesReceived == 115200, "Frame not completed");
        Check(good.LargestBlock == 1024 && good.Writes == 114, "Wrong block count (including final 512-byte block)");

        BoundedLink bad = new BoundedLink(packet); bad.ErrorAtByte = 2048;
        bool rejected = false;
        try { AirspaceTransport.Send(bad,packet,sequence,500); }
        catch (IOException e) { rejected = e.Message.Contains("2048/115200"); }
        Check(rejected && !bad.Committed && bad.BytesReceived == 2048, "Firmware error was ignored");

        BoundedLink invalid = new BoundedLink(packet); invalid.InvalidBlock = true;
        rejected = false;
        try { AirspaceTransport.Send(invalid,packet,sequence,500); } catch (IOException) { rejected = true; }
        Check(rejected && invalid.BytesReceived == 0, "Oversized negotiated blocks accepted");

        BoundedLink absent = new BoundedLink(packet); absent.MissingReady = true;
        rejected = false;
        try { AirspaceTransport.Send(absent,packet,sequence,20); } catch (TimeoutException) { rejected = true; }
        Check(rejected && absent.BytesReceived == 0, "Payload sent to old/unready firmware");
    }
}
