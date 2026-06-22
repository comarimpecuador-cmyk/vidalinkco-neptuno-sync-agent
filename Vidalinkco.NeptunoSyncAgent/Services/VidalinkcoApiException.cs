namespace Vidalinkco.NeptunoSyncAgent.Services;

public sealed class VidalinkcoApiException : Exception
{
    public VidalinkcoApiException(string message, int statusCode, string responseBody)
        : base(message)
    {
        StatusCode = statusCode;
        ResponseBody = responseBody;
    }

    public int StatusCode { get; }

    public string ResponseBody { get; }
}
