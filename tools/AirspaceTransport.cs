using System;
using System.IO;
using System.IO.Ports;
using System.Diagnostics;
using System.Globalization;

// One acknowledged block is in flight at a time. Windows accepting a Write()
// does not mean the ESP32 application has drained its finite USB RX queue.
public interface IAirspaceLink {
    void DiscardInput();
    void Write(byte[] bytes, int offset, int count);
    string ReadLine(int timeoutMs);
}

public static class AirspaceTransport {
    private sealed class SerialLink : IAirspaceLink {
        private readonly SerialPort port;
        public SerialLink(SerialPort serial) { port = serial; }
        public void DiscardInput() { port.DiscardInBuffer(); }
        public void Write(byte[] bytes, int offset, int count) { port.Write(bytes, offset, count); }
        public string ReadLine(int timeoutMs) { port.ReadTimeout = timeoutMs; return port.ReadLine(); }
    }

    private static string Receive(IAirspaceLink link, Stopwatch clock, int timeoutMs, string stage) {
        while (clock.ElapsedMilliseconds < timeoutMs) {
            try {
                string line = link.ReadLine((int)Math.Max(1, Math.Min(1000, timeoutMs - clock.ElapsedMilliseconds))).Trim();
                if (line.StartsWith("ERR ", StringComparison.Ordinal))
                    throw new IOException("Display rejected " + stage + ": " + line);
                return line;
            } catch (TimeoutException) { }
        }
        throw new TimeoutException("No acknowledgement for " + stage + ". Check the COM port and airspace_usb firmware.");
    }

    private static int Ready(IAirspaceLink link, uint sequence, int timeoutMs) {
        Stopwatch clock = Stopwatch.StartNew();
        string prefix = "READY " + sequence.ToString(CultureInfo.InvariantCulture) + " ";
        while (true) {
            string line = Receive(link, clock, timeoutMs, "frame header");
            if (!line.StartsWith(prefix, StringComparison.Ordinal)) continue; // Ignore boot banner / old replies.
            int block;
            if (!Int32.TryParse(line.Substring(prefix.Length), NumberStyles.None, CultureInfo.InvariantCulture, out block) || block < 1 || block > 1024)
                throw new IOException("Invalid USB block size in: " + line);
            return block;
        }
    }

    private static void Acknowledged(IAirspaceLink link, string expected, int timeoutMs, string stage) {
        Stopwatch clock = Stopwatch.StartNew();
        while (Receive(link, clock, timeoutMs, stage) != expected) { }
    }

    public static void Send(SerialPort serial, byte[] packet, uint sequence) {
        Send(new SerialLink(serial), packet, sequence, 15000);
    }

    public static bool SupportsScene(SerialPort serial) {
        // A reconnect can arrive while the display is finishing its two-second map sweep.
        return SupportsScene(new SerialLink(serial), 3000);
    }

    public static bool SupportsTilt(SerialPort serial) {
        return Probe(new SerialLink(serial), 3000, (byte)'T', "CAP IPS4 TILT");
    }

    public static bool SupportsTopDownWater(SerialPort serial) {
        return Probe(new SerialLink(serial), 3000, (byte)'W', "CAP IPS4 WATER");
    }

    public static bool SupportsScene(IAirspaceLink link, int timeoutMs) {
        return Probe(link, timeoutMs, (byte)'?', "CAP IPS4");
    }

    private static bool Probe(IAirspaceLink link, int timeoutMs, byte command, string expected) {
        byte[] probe = { (byte)'I', (byte)'P', (byte)'S', command };
        link.DiscardInput();
        link.Write(probe, 0, probe.Length);
        Stopwatch clock = Stopwatch.StartNew();
        while (clock.ElapsedMilliseconds < timeoutMs) {
            try {
                if (link.ReadLine((int)Math.Max(1, timeoutMs - clock.ElapsedMilliseconds)).Trim() == expected)
                    return true;
            } catch (TimeoutException) { }
        }
        return false;
    }

    public static void Send(IAirspaceLink link, byte[] packet, uint sequence, int timeoutMs) {
        if (packet.Length < 16 || packet[0] != 'I' || packet[1] != 'P' || packet[2] != 'S')
            throw new ArgumentException("Expected an IPS2 image or IPS4 scene packet.");
        const int headerBytes = 16;
        int payloadBytes = packet.Length - headerBytes;
        if (!(packet[3] == '2' && payloadBytes == 115200) && !(packet[3] == '4' && payloadBytes >= 32))
            throw new ArgumentException("Packet version or length mismatch.");
        if (BitConverter.ToUInt32(packet, 4) != payloadBytes || BitConverter.ToUInt32(packet, 8) != sequence)
            throw new ArgumentException("Packet length or sequence mismatch.");
        link.DiscardInput();
        link.Write(packet, 0, headerBytes);
        int block = Ready(link, sequence, timeoutMs);
        for (int sent = 0; sent < payloadBytes;) {
            int count = Math.Min(block, payloadBytes - sent);
            link.Write(packet, headerBytes + sent, count);
            sent += count;
            string expected = sent == payloadBytes ? "OK " + sequence : "CHUNK " + sequence + " " + sent;
            Acknowledged(link, expected, timeoutMs, "packet " + sequence + ", received " + sent + "/" + payloadBytes + " bytes");
        }
    }
}
