#import "TextResponseSerializer.h"
#include "iconv.h"

NSString * const AFNetworkingOperationFailingURLResponseBodyKey = @"com.alamofire.serialization.response.error.body";
NSStringEncoding const SupportedEncodings[6] = { NSUTF8StringEncoding, NSWindowsCP1252StringEncoding, NSISOLatin1StringEncoding, NSISOLatin2StringEncoding, NSASCIIStringEncoding, NSUnicodeStringEncoding };

static NSError * AFErrorWithUnderlyingError(NSError *error, NSError *underlyingError) {
  if (!error) {
    return underlyingError;
  }

  if (!underlyingError || error.userInfo[NSUnderlyingErrorKey]) {
    return error;
  }

  NSMutableDictionary *mutableUserInfo = [error.userInfo mutableCopy];
  mutableUserInfo[NSUnderlyingErrorKey] = underlyingError;

  return [[NSError alloc] initWithDomain:error.domain code:error.code userInfo:mutableUserInfo];
}

static NSData * cleanUTF8(NSData *data) {
    // this function is from
    // https://stackoverflow.com/questions/3485190/nsstring-initwithdata-returns-null
    //
    //
    iconv_t cd = iconv_open("UTF-8", "UTF-8"); // convert to UTF-8 from UTF-8
    int one = 1;
    iconvctl(cd, ICONV_SET_DISCARD_ILSEQ, &one); // discard invalid characters
    size_t inbytesleft, outbytesleft;
    inbytesleft = outbytesleft = data.length;
    char *inbuf  = (char *)data.bytes;
    char *outbuf = malloc(sizeof(char) * data.length);
    char *outptr = outbuf;
    if (iconv(cd, &inbuf, &inbytesleft, &outptr, &outbytesleft)
        == (size_t)-1) {
        NSLog(@"this should not happen, seriously");
        return nil;
    }
    NSData *result = [NSData dataWithBytes:outbuf length:data.length - outbytesleft];
    iconv_close(cd);
    free(outbuf);
    return result;
}

static BOOL AFErrorOrUnderlyingErrorHasCodeInDomain(NSError *error, NSInteger code, NSString *domain) {
  if ([error.domain isEqualToString:domain] && error.code == code) {
    return YES;
  } else if (error.userInfo[NSUnderlyingErrorKey]) {
    return AFErrorOrUnderlyingErrorHasCodeInDomain(error.userInfo[NSUnderlyingErrorKey], code, domain);
  }

  return NO;
}

@implementation TextResponseSerializer

+ (instancetype)serializer {
  TextResponseSerializer *serializer = [[self alloc] init];
  return serializer;
}

- (instancetype)init {
  self = [super init];

  if (!self) {
    return nil;
  }

  self.acceptableContentTypes = nil;

  return self;
}


- (NSString*)decodeResponseData:(NSData*)rawResponseData withEncoding:(CFStringEncoding)cfEncoding {
  NSStringEncoding nsEncoding;
  NSString* decoded = nil;

  if (cfEncoding != kCFStringEncodingInvalidId) {
    nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding);
  }

  NSData* cleanedData = cleanUTF8(rawResponseData);

  for (int i = 0; i < sizeof(SupportedEncodings) / sizeof(NSStringEncoding) && !decoded; ++i) {
    if (cfEncoding == kCFStringEncodingInvalidId || nsEncoding == SupportedEncodings[i]) {
      decoded = [[NSString alloc] initWithData:cleanedData encoding:SupportedEncodings[i]];
    }
  }

  return decoded;
}

- (CFStringEncoding) getEncoding:(NSURLResponse *)response {
  CFStringEncoding encoding = kCFStringEncodingInvalidId;

  if (response.textEncodingName) {
    encoding = CFStringConvertIANACharSetNameToEncoding((CFStringRef)response.textEncodingName);
  }

  return encoding;
}

#pragma mark -

- (BOOL)validateResponse:(NSHTTPURLResponse *)response
                    data:(NSData *)data
                 decoded:(NSString **)decoded
                   error:(NSError * __autoreleasing *)error
{
  BOOL responseIsValid = YES;
  NSError *validationError = nil;

  if (response && [response isKindOfClass:[NSHTTPURLResponse class]]) {
    if (data) {
      *decoded = [self decodeResponseData:data withEncoding:[self getEncoding:response]];
    }

    if (data && !*decoded) {
      NSMutableDictionary *mutableUserInfo = [@{
        NSURLErrorFailingURLErrorKey:[response URL],
        AFNetworkingOperationFailingURLResponseErrorKey: response,
        AFNetworkingOperationFailingURLResponseDataErrorKey: data,
        AFNetworkingOperationFailingURLResponseBodyKey: @"Could not decode response data due to invalid or unknown charset encoding",
      } mutableCopy];

      validationError = AFErrorWithUnderlyingError([NSError errorWithDomain:AFURLResponseSerializationErrorDomain code:NSURLErrorBadServerResponse userInfo:mutableUserInfo], validationError);
      responseIsValid = NO;
    } else if (self.acceptableStatusCodes && ![self.acceptableStatusCodes containsIndex:(NSUInteger)response.statusCode] && [response URL]) {
      NSMutableDictionary *mutableUserInfo = [@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedStringFromTable(@"Request failed: %@ (%ld)", @"AFNetworking", nil), [NSHTTPURLResponse localizedStringForStatusCode:response.statusCode], (long)response.statusCode],
        NSURLErrorFailingURLErrorKey: [response URL],
        AFNetworkingOperationFailingURLResponseErrorKey: response,
      } mutableCopy];

      if (data) {
        mutableUserInfo[AFNetworkingOperationFailingURLResponseDataErrorKey] = data;
        mutableUserInfo[AFNetworkingOperationFailingURLResponseBodyKey] = *decoded;
      }

      validationError = AFErrorWithUnderlyingError([NSError errorWithDomain:AFURLResponseSerializationErrorDomain code:NSURLErrorBadServerResponse userInfo:mutableUserInfo], validationError);
      responseIsValid = NO;
    }
  }

  if (error && !responseIsValid) {
    *error = validationError;
  }

  return responseIsValid;
}

#pragma mark - AFURLResponseSerialization

- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
  NSString* decoded = nil;

  if (![self validateResponse:(NSHTTPURLResponse *)response data:data decoded:&decoded error:error]) {
    if (!error || AFErrorOrUnderlyingErrorHasCodeInDomain(*error, NSURLErrorCannotDecodeContentData, AFURLResponseSerializationErrorDomain)) {
      return nil;
    }
  }

  return decoded;
}

@end
