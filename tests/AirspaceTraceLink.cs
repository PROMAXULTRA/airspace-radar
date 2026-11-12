using System.IO.Ports;
using System.Collections.Generic;

public sealed class AirspaceTraceLink : IAirspaceLink {
    private readonly SerialPort port;
    public readonly List<string> DrawLines = new List<string>();
    public AirspaceTraceLink(SerialPort serial) { port = serial; }
    public void DiscardInput() { port.DiscardInBuffer(); DrawLines.Clear(); }
    public void Write(byte[] bytes, int offset, int count) { port.Write(bytes,offset,count); }
    public string ReadLine(int timeoutMs) {
        port.ReadTimeout = timeoutMs;
        string line = port.ReadLine().Trim();
        if (line.StartsWith("DRAW ")) DrawLines.Add(line);
        return line;
    }
}
