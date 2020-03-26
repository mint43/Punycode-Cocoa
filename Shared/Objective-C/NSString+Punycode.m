//
//  NSString+Punycode.m
//  Punycode
//
//  Created by Wevah on 2005.11.02.
//  Copyright 2005-2012 Derailer. All rights reserved.
//
//  Distributed under an MIT-style license; please
//  see the included LICENSE file for details.
//


#import "NSString+Punycode.h"

#if defined(PUNYCODE_COCOA_USE_WEBKIT)

#import "WebNSURLExtras.h"

#elif defined(PUNYCODE_COCOA_USE_ICU)

//#import "unicode/uidna.h"
#import "uidna-min.h"
#define HOST_NAME_BUFFER_LENGTH 2048 // Name and size from WebKit.

#endif


#if __has_feature(objc_arc)
#define PUNYCODE_COCOA_AUTORELEASE(x) x
#else
#define PUNYCODE_COCOA_AUTORELEASE(x) [x autorelease]
#endif

#if !defined(PUNYCODE_COCOA_USE_WEBKIT) && !defined(PUNYCODE_COCOA_USE_ICU)

// Encoding/decoding adapted/lifted from the example code in the IDNA Punycode spec (RFC 3492).
// For some other stuff, see RFC 3490 (Internationalizing Domain Names in Applications)

enum {
	base = 36,
	tmin = 1,
	tmax = 26,
	skew = 38,
	damp = 700,
	initial_bias = 72,
	initial_n = 0x80,
	delimiter = '-'
};

/* basic(cp) tests whether cp is a basic code point: */
#define basic(cp) ((unsigned)(cp) < 0x80)

/* delim(cp) tests whether cp is a delimiter: */
#define delim(cp) ((cp) == delimiter)

/* decode_digit(cp) returns the numeric value of a basic code */
/* point (for use in representing integers) in the range 0 to */
/* base-1, or base if cp is does not represent a value.       */

static NSUInteger decode_digit(unsigned cp)
{
	return  cp - 48 < 10 ? cp - 22 :  cp - 65 < 26 ? cp - 65 :
	cp - 97 < 26 ? cp - 97 : base;
}

/* encode_digit(d,flag) returns the basic code point whose value      */
/* (when used for representing integers) is d, which needs to be in   */
/* the range 0 to base-1.  The lowercase form is used unless flag is  */
/* nonzero, in which case the uppercase form is used.  The behavior   */
/* is undefined if flag is nonzero and digit d has no uppercase form. */

static char encode_digit(unsigned d, int flag)
{
	return (char)(d + 22 + 75 * (d < 26) - ((unsigned)(flag != 0) << 5));
	/*  0..25 map to ASCII a..z or A..Z */
	/* 26..35 map to ASCII 0..9         */
}

/* flagged(bcp) tests whether a basic code point is flagged */
/* (uppercase).  The behavior is undefined if bcp is not a  */
/* basic code point.                                        */

#define flagged(bcp) ((unsigned)(bcp) - 65 < 26)

/*** Platform-specific constants ***/

/* maxint is the maximum value of a punycode_uint variable: */
static const unsigned maxint = UINT_MAX;

/*** Bias adaptation function ***/

static NSUInteger adapt(unsigned delta, unsigned numpoints, BOOL firsttime) {
	unsigned k;
	
	delta = firsttime ? delta / damp : delta >> 1;
	delta += delta / numpoints;
	
	for (k = 0;  delta > ((base - tmin) * tmax) / 2;  k += base) {
		delta /= base - tmin;
	}
	
	return k + (base - tmin + 1) * delta / (delta + skew);
}

#endif // PUNYCODE_COCOA_USE_WEBKIT

@interface NSString (PunycodePrivate)

@property (readonly, copy)	NSDictionary<NSString *, NSString *>	*URLParts;
@property (readonly, copy)	NSString								*stringByDeletingVariationSelectors;

@end

@implementation NSString (Punycode)


#if defined(PUNYCODE_COCOA_USE_ICU)

static UIDNA *uidnaEncoder() {
	static UIDNA *encoder;

	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		UErrorCode err = U_ZERO_ERROR;
		encoder = uidna_openUTS46(UIDNA_CHECK_BIDI | UIDNA_CHECK_CONTEXTJ | UIDNA_NONTRANSITIONAL_TO_UNICODE | UIDNA_NONTRANSITIONAL_TO_ASCII, &err);

		if (U_FAILURE(err))
			NSLog(@"%d", err);
	});

	return encoder;
}

#elif !defined(PUNYCODE_COCOA_USE_WEBKIT)

/*** Main encode function ***/

#if BYTE_ORDER == LITTLE_ENDIAN
#define UTF32_ENCODING NSUTF32LittleEndianStringEncoding
#elif BYTE_ORDER == BIG_ENDIAN
#define UTF32_ENCODING NSUTF32BigEndianStringEncoding
#else
#error Unsupported endianness!
#endif

- (const UTF32Char *)longCharactersWithCount:(NSUInteger *)count {
	NSData *data = [self dataUsingEncoding:UTF32_ENCODING];
	*count = data.length / sizeof(UTF32Char);
	return data.bytes;
}

- (NSString *)stringByDeletingIgnoredCharacters {
	static NSRegularExpression *regex;

	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		regex = [[NSRegularExpression alloc] initWithPattern:@"[\u00AD\u034F\u1806\u180B\u180C\u180D\u200B\u200C\u200D\u2060\uFE00-\uFE0F\uFEFF]" options:0 error:nil];
	});

	return [regex stringByReplacingMatchesInString:self options:0 range:(NSRange){ .location = 0, .length = self.length} withTemplate:@""];
}

- (NSString *)punycodeEncodedString {
	NSString *variationStripped = self.stringByDeletingIgnoredCharacters;
	NSMutableString *ret = [NSMutableString string];
	unsigned delta, outLen, bias, j, m, q, k, t;
	NSUInteger input_length;
	const UTF32Char *longchars = [variationStripped longCharactersWithCount:&input_length];
	
	UTF32Char n = initial_n;
	delta = outLen = 0;
	bias = initial_bias;
		
	for (j = 0;  j < input_length;  ++j) {
		if (basic(longchars[j])) {
			[ret appendFormat:@"%C", (unichar)longchars[j]];
			++outLen;
		}
	}
	
	NSUInteger b;
	NSUInteger h = b = outLen;
	
	if (b > 0)
		[ret appendFormat:@"%C", (unichar)delimiter];
	
	/* Main encoding loop: */
	
	while (h < input_length) {
		for (m = maxint, j = 0;  j < input_length;  ++j) {
			unsigned c = longchars[j];
			
			if (c >= n && c < m)
				m = longchars[j];
		}
		
		if (m - n > (maxint - delta) / (h + 1))
			return nil; //punycode_overflow;
		delta += (m - n) * (h + 1);
		n = m;
		
		for (j = 0;  j < input_length;  ++j) {
			unsigned c = longchars[j];
			
			if (c < n /* || basic([self characterAtIndex:j]) */ ) {
				if (++delta == 0)
					return nil; //punycode_overflow;
			}
			
			if (c == n) {				
				for (q = delta, k = base;  ;  k += base) {
					t = k <= bias /* + tmin */ ? tmin :     /* +tmin not needed */
						k >= bias + tmax ? tmax : k - bias;
					if (q < t)
						break;
					[ret appendFormat:@"%C", (unichar)encode_digit(t + (q - t) % (base - t), 0)];
					q = (q - t) / (base - t);
				}
				
				[ret appendFormat:@"%c", encode_digit(q, 0)];
				bias = (unsigned)adapt(delta, (unsigned)h + 1, h == b);
				delta = 0;
				++h;
			}
		}
		
		++delta;
		++n;
	}
	
	return ret;
}

/*** Main decode function ***/

- (NSString *)punycodeDecodedString {
	NSUInteger b, i, j;
	
	NSMutableData *utf32data = [NSMutableData data];
	
	/* Initialize the state: */
	NSUInteger input_length = self.length;
	UTF32Char n = initial_n;
	NSUInteger outLen = i = 0;
	NSUInteger bias = initial_bias;
	
	for (b = j = 0;  j < input_length;  ++j)
		if (delim([self characterAtIndex:j]))
			b = j;
		
	for (j = 0;  j < b;  ++j) {
		UTF32Char c = (UTF32Char)[self characterAtIndex:j];
		
		if (!basic([self characterAtIndex:j]))
			return nil; //punycode_bad_input;
		
		[utf32data appendBytes:&c length:sizeof(c)];
		++outLen;
	}
	
	for (NSUInteger inPos = b > 0 ? b + 1 : 0; inPos < input_length; ++outLen, ++i) {
		NSUInteger k, w, t, oldi;
		
		for (oldi = i, w = 1, k = base; /* nada */ ; k += base) {
			if (inPos >= input_length)
				return nil; // punycode_bad_input;
			unsigned digit = (unsigned)decode_digit([self characterAtIndex:inPos++]);
			if (digit >= base)
				return nil; // punycode_bad_input;
			if (digit > (maxint - i) / w)
				return nil; // punycode_overflow;
			i += digit * w;
			t = k <= bias /* + tmin */ ? tmin :     /* +tmin not needed */
				k >= bias + tmax ? tmax : k - bias;
			if (digit < t)
				break;
			if (w > maxint / (base - t))
				return nil; // punycode_overflow;
			w *= (base - t);
		}
		
		bias = adapt((unsigned)i - (unsigned)oldi, (unsigned)outLen + 1, oldi == 0);
		
		if (i / (outLen + 1) > maxint - n)
			return nil; // punycode_overflow;
		n += i / (outLen + 1);
		i %= (outLen + 1);
		
		[utf32data replaceBytesInRange:NSMakeRange(i * sizeof(UTF32Char), 0) withBytes:&n length:sizeof(n)];
	}
	
	return PUNYCODE_COCOA_AUTORELEASE([[NSString alloc] initWithData:utf32data encoding:UTF32_ENCODING]);
}

#endif // PUNYCODE_COCOA_USE_WEBKIT

- (NSString *)IDNAEncodedString {
#if defined(PUNYCODE_COCOA_USE_WEBKIT)
	return [self _web_encodeHostName];
#elif defined(PUNYCODE_COCOA_USE_ICU)
	if (self.length == 0)
		return @"";

	if (self.length > HOST_NAME_BUFFER_LENGTH)
		return nil;

	UIDNA *encoder = uidnaEncoder();

	UChar name[HOST_NAME_BUFFER_LENGTH];
	UChar dest[HOST_NAME_BUFFER_LENGTH];

	NSRange range = (NSRange){ 0, self.length };

	[self getCharacters:name range:range];

	UIDNAInfo info = UIDNA_INFO_INITIALIZER;
	UErrorCode err = U_ZERO_ERROR;

	int32_t numChars = uidna_nameToASCII(encoder, name, (int32_t)range.length, dest, HOST_NAME_BUFFER_LENGTH, &info, &err);

	return [NSString stringWithCharacters:dest length:numChars];
#else
	NSCharacterSet *nonAscii = [NSCharacterSet characterSetWithRange:NSMakeRange(1, 127)].invertedSet;
	NSMutableString *ret = [NSMutableString string];
	NSScanner *s = [NSScanner scannerWithString:self.precomposedStringWithCompatibilityMapping];
	NSCharacterSet *dotAt = [NSCharacterSet characterSetWithCharactersInString:@".@"];
	NSString *input = nil;
	
	while (!s.atEnd) {
		if ([s scanUpToCharactersFromSet:dotAt intoString:&input]) {
			if ([input rangeOfCharacterFromSet:nonAscii].location != NSNotFound) {
				[ret appendFormat:@"xn--%@", input.punycodeEncodedString];
			} else
				[ret appendString:input];
		}
		
		if ([s scanCharactersFromSet:dotAt intoString:&input])
			[ret appendString:input];
	}
		
	return ret;
#endif
}

- (NSString *)IDNADecodedString {
#if defined(PUNYCODE_COCOA_USE_WEBKIT)
	return [self _web_decodeHostName];
#elif defined(PUNYCODE_COCOA_USE_ICU)
	if (self.length == 0)
		return @"";

	if (self.length > HOST_NAME_BUFFER_LENGTH)
		return nil;

	UIDNA *encoder = uidnaEncoder();

	UChar name[HOST_NAME_BUFFER_LENGTH];
	UChar dest[HOST_NAME_BUFFER_LENGTH];

	NSRange range = (NSRange){ 0, self.length };

	[self getCharacters:name range:range];

	UIDNAInfo info = UIDNA_INFO_INITIALIZER;
	UErrorCode err = U_ZERO_ERROR;

	int32_t numChars = uidna_nameToUnicode(encoder, name, (int32_t)range.length, dest, HOST_NAME_BUFFER_LENGTH, &info, &err);

	return [NSString stringWithCharacters:dest length:numChars];
#else
	NSMutableString *ret = [NSMutableString string];
	NSScanner *s = [NSScanner scannerWithString:self];
	NSCharacterSet *dotAt = [NSCharacterSet characterSetWithCharactersInString:@".@"];
	NSString *input = nil;
	
	while (!s.atEnd) {
		if ([s scanUpToCharactersFromSet:dotAt intoString:&input]) {
			if ([input.lowercaseString hasPrefix:@"xn--"]) {
				NSString *substr = [input substringFromIndex:4].punycodeDecodedString;
				
				if (substr)
					[ret appendString:substr];
			} else
				[ret appendString:input];
		}
		
		if ([s scanCharactersFromSet:dotAt intoString:&input])
			[ret appendString:input];
	}
	
	return ret;
#endif
}

- (NSDictionary<NSString *, NSString *> *)URLParts {
	NSCharacterSet *colonSlash = [NSCharacterSet characterSetWithCharactersInString:@":/"];
	NSCharacterSet *slashQuestion = [NSCharacterSet characterSetWithCharactersInString:@"/?"];
	NSScanner *s = [NSScanner scannerWithString:self.precomposedStringWithCompatibilityMapping];
	NSString *scheme = @"";
	NSString *delim = @"";
	NSString *host = @"";
	NSString *path = @"";
	NSString *username = nil;
	NSString *password = nil;
	NSString *fragment = nil;
	
	if ([s scanUpToCharactersFromSet:colonSlash intoString:&host]) {
		if ([s scanCharactersFromSet:colonSlash intoString:&delim]) {

			if ([delim hasPrefix:@":"]) {
				scheme = host;

				if (!s.atEnd)
					[s scanUpToCharactersFromSet:slashQuestion intoString:&host];
				else
					host = @"";
			}
		}
	} else if ([s scanString:@"//" intoString:&delim]) {
		if (!s.isAtEnd) {
			[s scanUpToCharactersFromSet:slashQuestion intoString:&host];
		}
	}
	
	if (!s.atEnd)
		[s scanUpToString:@"#" intoString:&path];

	if (!s.atEnd) {
		[s scanString:@"#" intoString:nil];
		[s scanUpToCharactersFromSet:[NSCharacterSet newlineCharacterSet] intoString:&fragment];
	}

	NSArray<NSString *> *usernamePasswordHostPort = [host componentsSeparatedByString:@"@"];

	switch (usernamePasswordHostPort.count) {
		default: {
			NSArray<NSString *> *usernamePassword = [usernamePasswordHostPort[0] componentsSeparatedByString:@":"];
			username = usernamePassword[0];
			password = usernamePassword.count > 1 ? usernamePassword[1] : nil;
			host = usernamePasswordHostPort[1];
			break;
		}
		case 1:
			host = usernamePasswordHostPort[0];
			break;
		case 0:
			// error
			break;
	}
	
	NSMutableDictionary *parts = [NSMutableDictionary dictionaryWithObjectsAndKeys:
								  scheme,	@"scheme",
								  delim,	@"delim",
								  host,		@"host",
								  path,		@"path",
								  nil];
	
	if (username)
		parts[@"username"] = username;
	if (password)
		parts[@"password"] = password;
	if (fragment)
		parts[@"fragment"] = fragment;
	
	return parts;
}

- (NSString *)encodedURLString {
#if defined(PUNYCODE_COCOA_USE_WEBKIT)
	return [NSURL _web_URLWithUserTypedString:self].absoluteString;
#else
	// We can't get the parts of an URL for an international domain name, so a custom method is used instead.
	NSDictionary *urlParts = self.URLParts;
	NSString *path = urlParts[@"path"];

	// "path" here is really "path+query", so we're allowing '?' as well as '%'.
	NSMutableCharacterSet *allowedCharacters = [[NSCharacterSet URLPathAllowedCharacterSet] mutableCopy];
	[allowedCharacters addCharactersInRange:(NSRange){ '%', 1 }];
	[allowedCharacters addCharactersInRange:(NSRange){ '?', 1 }];
	path = [path stringByAddingPercentEncodingWithAllowedCharacters:allowedCharacters];
#if !__has_feature(objc_arc)
	[allowedCharacters release];
#endif

	NSMutableString *ret = [NSMutableString stringWithFormat:@"%@%@", urlParts[@"scheme"], urlParts[@"delim"]];
	if (urlParts[@"username"]) {
		if (urlParts[@"password"]) {
			[ret appendFormat:@"%@:%@@",
			 [urlParts[@"username"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLUserAllowedCharacterSet]],
			 [urlParts[@"password"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPasswordAllowedCharacterSet]]];
		} else
			[ret appendFormat:@"%@@", [urlParts[@"username"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLUserAllowedCharacterSet]]];
	}
	
	[ret appendFormat:@"%@%@", [urlParts[@"host"] IDNAEncodedString], path];
	
    NSString *fragment = urlParts[@"fragment"];
    if (fragment) {
		NSMutableCharacterSet *fragmentAllowedCharacters = [[NSCharacterSet URLFragmentAllowedCharacterSet] mutableCopy];
		[fragmentAllowedCharacters addCharactersInRange:(NSRange) { '%' , 1 }];
		fragment = [fragment stringByAddingPercentEncodingWithAllowedCharacters:fragmentAllowedCharacters];
#if !__has_feature(objc_arc)
		[fragmentAllowedCharacters release];
#endif
        [ret appendFormat:@"#%@", fragment];
    }
			
	return ret;
#endif
}

- (NSString *)decodedURLString {
#if defined(PUNYCODE_COCOA_USE_WEBKIT)
	return [[NSURL URLWithString:self] _web_userVisibleString];
#else
	NSDictionary<NSString *, NSString *> *urlParts = self.URLParts;

	NSString *username = urlParts[@"username"];
	NSString *password = urlParts[@"password"];
	NSString *usernamePassword = nil;

	if (username) {
		if (password)
			usernamePassword = [NSString stringWithFormat:@"%@:%@@",
								username.stringByRemovingPercentEncoding, password.stringByRemovingPercentEncoding];
		else
			usernamePassword = [NSString stringWithFormat:@"%@@", username.stringByRemovingPercentEncoding];
	}

	NSString *ret = [NSString stringWithFormat:@"%@%@%@%@%@", urlParts[@"scheme"], urlParts[@"delim"], usernamePassword ?: @"", (urlParts[@"host"]).IDNADecodedString, urlParts[@"path"].stringByRemovingPercentEncoding ?: @""];

	NSString *fragment = urlParts[@"fragment"];

	if (fragment) {
		fragment = fragment.stringByRemovingPercentEncoding;
		ret = [ret stringByAppendingFormat:@"#%@", fragment];
	}

	return ret;
#endif
}

@end

@implementation NSURL (Punycode)

+ (instancetype)URLWithUnicodeString:(NSString *)URLString {
#if defined(PUNYCODE_COCOA_USE_WEBKIT)
	return [NSURL _webkit_URLWithUserTypedString:URLString];
#else
	return [NSURL URLWithString:URLString.encodedURLString];
#endif
}

- (NSString *)decodedURLString {
#if defined(PUNYCODE_COCOA_USE_WEBKIT)
	return [self _web_userVisibleString];
#else
	return self.absoluteString.decodedURLString;
#endif
}

+ (instancetype)URLWithUnicodeString:(NSString *)URLString relativeToURL:(NSURL *)baseURL {
	NSDictionary<NSString *, NSString *> *parts = URLString.URLParts;

	if (parts[@"scheme"].length != 0) {
		URLString = URLString.encodedURLString;
	}

	return [self URLWithString:URLString relativeToURL:baseURL];
}

@end