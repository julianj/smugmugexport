//
//  SMESession.m
//  SmugMugExport
//
//  Created by Aaron Evans on 10/7/06.
//  Copyright 2006 Aaron Evans. All rights reserved.
//

#import "SMESession.h"
#import "SMGlobals.h"
#import "SMRequest.h"
#import "SMDecoder.h"
#import "SMEUserDefaultsAdditions.h"
#import "SMJSONDecoder.h"
#import "SMAlbum.h"
#import "SMImageRef.h"
#import "SMAlbumInfo.h"
#import "SMResponse.h"
#import "SMSessionInfo.h"
#import "SMCategory.h"
#import "SMSubCategory.h"
#import "SMImageURLs.h"

/*
 * Class wraps the repetitive process of invoking remote smugmgu methods, asynchronously getting a callback
 * upon request completion, and handling the result.
 * 
  send message invokeMethodAndHandleResponse:req to handler
   
  upon requestComplete for request r {
	on main thread, do:
		[target callback:[transformer transform:r]]
  }
 */
@interface ResponseHandler : NSObject {
	NSInvocation *inv;
	NSInvocation *transformInv;
}
+(ResponseHandler *)responseHandler:(id)target callback:(SEL)callback transformer:(id)transformer transformSel:(SEL)transformSel;
-(id)initWithResponseHandler:(id)target callback:(SEL)callback transformer:(id)transformer transformSel:(SEL)transformSel;
-(void)invokeMethodAndHandleResponse:(SMRequest *)req url:(NSURL *)aURL dict:(NSDictionary *)dict;
@end

@implementation ResponseHandler

+(ResponseHandler *)responseHandler:(id)target callback:(SEL)callback transformer:(id)transformer transformSel:(SEL)transformSel {
	return [[[[self class] alloc] initWithResponseHandler:target callback:callback transformer:transformer transformSel:transformSel] autorelease];
}

-(id)initWithResponseHandler:(id)target callback:(SEL)callback transformer:(id)aTransformer transformSel:(SEL)transformSel {
	if(! (self = [super init]))
		return nil;
	
	NSMethodSignature *sig = [[target class] instanceMethodSignatureForSelector:callback];
	if(nil == sig) {
		NSLog(@"Invalid callback for class: %@ selector: %@", NSStringFromClass([target class]), NSStringFromSelector(callback));
		return  nil;
	}
	
	inv = [[NSInvocation invocationWithMethodSignature:sig] retain];
	[inv setSelector:callback];
	[inv setTarget:target];
	[inv retainArguments];
	
	
	NSMethodSignature *transformSig = [[aTransformer class] instanceMethodSignatureForSelector:transformSel];
	if(nil == transformSig && transformSel != nil) {
		NSLog(@"Invalid transform callback for class: %@ selector: %@", NSStringFromClass([aTransformer class]), NSStringFromSelector(transformSel));
		return  nil;
	} else if(transformSig != nil) {
		transformInv = [[NSInvocation invocationWithMethodSignature:transformSig] retain];
		[transformInv setSelector:transformSel];
		[transformInv setTarget:aTransformer];
		[transformInv retainArguments];
	}	
	
	return self;
}

-(void)dealloc {
	[inv release];
	[transformInv release];
	
	[super dealloc];
}

-(void)invokeMethodAndHandleResponse:(SMRequest *)req url:(NSURL *)aURL dict:(NSDictionary *)dict {
	[req invokeMethodWithURL:aURL
				 requestDict:dict
			responseCallback:@selector(transformResult:)
			  responseTarget:self];
}

-(void)transformResult:(SMRequest *)req {
	if([[inv methodSignature] numberOfArguments] == 3) {
		id arg = nil;
		if(transformInv != nil && [[transformInv methodSignature] numberOfArguments] == 3) {
			[transformInv setArgument:&req atIndex:2];
			[transformInv invoke];
			[transformInv getReturnValue:&arg];
		}
		
		[inv setArgument:&arg atIndex:2];
		[arg retain]; // not retained by retainArguments above
	}
//	[inv invoke];
	[inv performSelectorOnMainThread:@selector(invoke) withObject:nil waitUntilDone:YES];
}

@end

@interface SMESession (Private)
-(NSString *)sessionID;
-(void)setSessionID:(NSString *)anID;

-(NSURL *)baseRequestUrl;

-(NSDictionary *)defaultNewAlbumPreferences;
-(void)newAlbumCreationDidComplete:(SMRequest *)req;
-(NSString *)smugMugNewAlbumKeyForPref:(NSString *)preferenceKey;
-(SMRequest *)createRequest;
-(SMRequest *)lastUploadRequest;
-(void)setLastUploadRequest:(SMRequest *)request;	
@end

static const NSTimeInterval AlbumRefreshDelay = 1.0;

@interface NSDictionary (SMAdditions)
-(NSComparisonResult)compareByAlbumId:(NSDictionary *)aDict;
@end

@implementation NSDictionary (SMAdditions)
-(NSComparisonResult)compareByAlbumId:(NSDictionary *)aDict {
	
	if([self objectForKey:@"id"] == nil)
		return NSOrderedAscending;
	
	if([aDict objectForKey:@"id"] == nil)
		return NSOrderedDescending;
		
	return [[aDict objectForKey:@"id"] intValue] - [[self objectForKey:@"id"] intValue];
}

-(NSComparisonResult)compareByTitle:(NSDictionary *)aDict {
	return [[self objectForKey:@"Title"] caseInsensitiveCompare:[aDict objectForKey:@"Title"]];
}
@end

#define NO_CATEGORIES_FOUND_CODE 15

@implementation SMESession

+(SMESession *)session {
	return [[[[self class] alloc] init] autorelease];
}

-(void)dealloc {

	[[self sessionID] release];
	[[self lastUploadRequest] release];
	
	[super dealloc];
}

-(NSObject<SMDecoder> *)decoder {
	return [SMJSONDecoder decoder];
}

-(SMRequest *)createRequest {
	return [SMRequest request];
}

#pragma mark Miscellaneous Get/Set Methods

-(NSURL *)baseRequestUrl {
	return [NSURL URLWithString:@"https://api.smugmug.com/hack/json/1.2.0/"];
}
	
-(NSString *)sessionID {
	return sessionID;
}

-(void)setSessionID:(NSString *)anID {
	if(sessionID != anID) {
		[sessionID release];
		sessionID = [anID retain];
	}
}

#pragma mark Login/Logout Methods

-(void)invokeMethodAndTransform:(NSURL *)aUrl
					requestDict:(NSDictionary *)dict
					   callback:(SEL)callback
						 target:(id)target
					transformer:(id)transformer 
				   transformSel:(SEL)transformSel{
	ResponseHandler *handler = [ResponseHandler responseHandler:target callback:callback transformer:transformer transformSel:transformSel];
	[handler invokeMethodAndHandleResponse:[self createRequest]
									   url:[self baseRequestUrl]
									  dict:dict];
}

-(void)loginWithTarget:(id)target callback:(SEL)sel username:(NSString *)username password:(NSString *)password apiKey:(NSString *)apiKey {
	[self invokeMethodAndTransform:[self baseRequestUrl]
					   requestDict:[NSDictionary dictionaryWithObjectsAndKeys:
									 @"smugmug.login.withPassword", @"method",
									 username, @"EmailAddress",
									 password, @"Password",
									 apiKey, @"APIKey", nil]
						  callback:sel
							target:target
					   transformer:self
					  transformSel:@selector(transformLoginRequest:)];
}

-(SMResponse *)transformLoginRequest:(SMRequest *)req {
	SMResponse* resp = [SMResponse responseWithData:[req data] decoder:[self decoder]];
	SMSessionInfo *info = (SMSessionInfo *)[SMSessionInfo dataWithSourceData:[[resp response] objectForKey:@"Login"]];
	[resp setSMData:info];
	
	// the only state of a session
	[self setSessionID:[info sessionId]];	
	return resp;
}

-(void)validateSessionId {
	if([self sessionID] == nil)
		@throw [NSException exceptionWithName:NSLocalizedString(@"InvalidSessionException", @"Exception name for invalid session exception")
									   reason:NSLocalizedString(@"Session id is invalid", @"Error string when session id is invalid.")
									 userInfo:NULL];
}


-(void)fetchAlbumsWithTarget:(id)target
					callback:(SEL)callback {
	[self validateSessionId];

	if(EnableAlbumFetchDelay())
		[NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:AlbumRefreshDelay]];
		
	[self invokeMethodAndTransform:[self baseRequestUrl]
					   requestDict:[NSDictionary dictionaryWithObjectsAndKeys:
									@"smugmug.albums.get", @"method",
									[self sessionID], @"SessionID", nil]
						  callback:callback
							target:target
					   transformer:self
					  transformSel:@selector(transformAlbumsRequest:)];	
}

-(SMResponse *)transformAlbumsRequest:(SMRequest *)req {
	SMResponse *resp = [SMResponse responseWithData:[req data] decoder:[self decoder]];

	NSMutableArray *result = [NSMutableArray array];
	NSEnumerator *albumEnum = [[[resp response] objectForKey:@"Albums"] objectEnumerator];
	NSDictionary *albumDict = nil;
	while(albumDict = [albumEnum nextObject])
		[result addObject:[SMAlbum albumWithDictionary:[NSMutableDictionary dictionaryWithDictionary:albumDict]]];
	
	[resp setSMData:[NSArray arrayWithArray:result]];
	return resp;
}

-(void)fetchCategoriesWithTarget:(id)target callback:(SEL)callback {
	[self validateSessionId];
	[self invokeMethodAndTransform:[self baseRequestUrl]
					   requestDict:[NSDictionary dictionaryWithObjectsAndKeys:
									@"smugmug.categories.get", @"method",
									[self sessionID], @"SessionID", nil]
						  callback:callback
							target:target
					   transformer:self
					  transformSel:@selector(transformCategoriesRequest:)];
}

-(SMResponse *)transformCategoryForCategoryKey:(NSString *)categoryKey categoryClass:(Class)categoryClass request:(SMRequest *)req{
	SMResponse *resp = [SMResponse responseWithData:[req data] decoder:[self decoder]];
	
	if([resp  code] == NO_CATEGORIES_FOUND_CODE) {
		[resp setSMData:[NSArray array]];
		return resp;
	}
	
	NSMutableArray *returnedCategories = [NSMutableArray arrayWithArray:[[resp response] objectForKey:categoryKey]];
	
	[returnedCategories sortUsingSelector:@selector(compareByTitle:)];
	NSEnumerator *e = [returnedCategories objectEnumerator];
	NSDictionary *dict = nil;
	NSMutableArray *result = [NSMutableArray array];
	while(dict = [e nextObject])
		[result addObject:[categoryClass dataWithSourceData:dict]];
	[resp setSMData:result];
	return resp;
}

-(SMResponse *)transformSubCategoriesRequest:(SMRequest *)req {
	return [self transformCategoryForCategoryKey:@"SubCategories" categoryClass:[SMSubCategory class] request:req];
}

-(SMResponse *)transformCategoriesRequest:(SMRequest *)req {
	return [self transformCategoryForCategoryKey:@"Categories" categoryClass:[SMCategory class] request:req];
}

-(void)fetchSubCategoriesWithTarget:(id)target callback:(SEL)callback {
	[self validateSessionId];
	[self invokeMethodAndTransform:[self baseRequestUrl]
					   requestDict:[NSDictionary dictionaryWithObjectsAndKeys:
									@"smugmug.subcategories.getAll", @"method",
									[self sessionID], @"SessionID", nil]
						  callback:callback
							target:target
					   transformer:self
					  transformSel:@selector(transformSubCategoriesRequest:)];
}

-(void)deleteAlbum:(SMAlbumRef *)ref withTarget:(id)target callback:(SEL)callback {
	[self validateSessionId];
	[self invokeMethodAndTransform:[self baseRequestUrl]
					   requestDict:[NSDictionary dictionaryWithObjectsAndKeys:
									@"smugmug.albums.delete", @"method",
									[self sessionID], @"SessionID",
									[ref albumId], @"AlbumID", nil]
						  callback:callback
							target:target
					   transformer:self
					  transformSel:@selector(transformDeleteResponse:)];
}

-(SMResponse *)transformDeleteResponse:(SMRequest *)req {
	SMResponse *resp = [SMResponse responseWithData:[req data] decoder:[self decoder]];
	return resp;
}


-(void)createNewAlbum:(SMAlbum *)album withTarget:(id)target callback:(SEL)callback {
	[self validateSessionId];
	
	NSMutableDictionary *requestDict = [NSMutableDictionary dictionaryWithDictionary:[album toDictionary]];
	[requestDict setObject:@"smugmug.albums.create" forKey:@"method"];
	[requestDict setObject:[self sessionID] forKey:@"SessionID"];
	
	[self invokeMethodAndTransform:[self baseRequestUrl]
					   requestDict:requestDict
						  callback:callback
							target:target
					   transformer:self
					  transformSel:@selector(transformCreateNewAlbumResponse:)];
}

-(SMResponse *)transformCreateNewAlbumResponse:(SMRequest *)req {
	SMResponse *resp = [SMResponse responseWithData:[req data] decoder:[self decoder]];
	return resp;
}

-(void)editAlbum:(SMAlbum *)album withTarget:(id)target callback:(SEL)callback {
	[self validateSessionId];
	
	NSMutableDictionary *reqArgs = [NSMutableDictionary dictionaryWithDictionary:[album toEditDictionary]];
	[reqArgs setObject:[self sessionID] forKey:@"SessionID"];
	[reqArgs setObject:@"smugmug.albums.changeSettings" forKey:@"method"];
	[self invokeMethodAndTransform:[self baseRequestUrl]
					   requestDict:reqArgs
						  callback:callback
							target:target
					   transformer:self
					  transformSel:@selector(transformEditAlbumResponse:)];
}

-(SMResponse *)transformEditAlbumResponse:(SMRequest *)req {
	SMResponse *resp = [SMResponse responseWithData:[req data] decoder:[self decoder]];
	return resp;
}

-(void)fetchExtendedAlbumInfo:(SMAlbumRef *)ref withTarget:(id)target callback:(SEL)callback {
	[self validateSessionId];
	
	NSMutableDictionary *args = [NSMutableDictionary dictionary];
	[args setObject:@"smugmug.albums.getInfo" forKey:@"method"];
	[args setObject:[self sessionID] forKey:@"SessionID"];
	[args setObject:[ref albumId] forKey:@"AlbumID"];
	[args setObject:[ref albumKey] forKey:@"AlbumKey"];
	[self invokeMethodAndTransform:[self baseRequestUrl]
					   requestDict:args
						  callback:callback
							target:target
					   transformer:self
					  transformSel:@selector(albumInfoFetchDidComplete:)];
}

-(SMResponse *)albumInfoFetchDidComplete:(SMRequest *)req {
	SMResponse *resp = [SMResponse responseWithData:[req data] decoder:[self decoder]];
	[resp setSMData:[SMAlbum albumWithDictionary:[[resp response] objectForKey:@"Album"]]];
	return resp;
}

-(void)fetchImageURLs:(SMImageRef *)ref withTarget:(id)target callback:(SEL)callback {
	[self validateSessionId];
	
	NSMutableDictionary *args = [NSMutableDictionary dictionary];
	[args setObject:@"smugmug.images.getURLs" forKey:@"method"];
	[args setObject:[self sessionID] forKey:@"SessionID"];
	[args setObject:[ref imageId] forKey:@"ImageID"];
	[args setObject:[ref imageKey] forKey:@"ImageKey"];
	[self invokeMethodAndTransform:[self baseRequestUrl]
					   requestDict:args
						  callback:callback
							target:target
					   transformer:self
					  transformSel:@selector(imageFetchDidComplete:)];
}

-(SMResponse *)imageFetchDidComplete:(SMRequest *)req {
	SMResponse *resp = [SMResponse responseWithData:[req data] decoder:[self decoder]];
	SMImageURLs *urls = (SMImageURLs *)[SMImageURLs dataWithSourceData:[[resp response] objectForKey:@"Image"]];
	[resp setSMData:urls];
	return resp;
}

#pragma mark Upload 

-(void)uploadImageData:(NSData *)imageData
			  filename:(NSString *)filename
				 album:(SMAlbumRef *)albumRef
			  caption:(NSString *)caption
			  keywords:(NSArray *)keywords
			  observer:(NSObject<SMUploadObserver>*)anObserver {
	
	SMRequest *uploadRequest = [self createRequest];
	[self setLastUploadRequest:uploadRequest];
	observer = anObserver; // delegate non-retaining semantics to avoid retain cycles
	[uploadRequest uploadImageData:imageData
						  filename:filename
						 sessionId:[self sessionID]
							 album:albumRef
						  caption:caption
						  keywords:keywords
						  observer:self];
}

-(NSObject<SMUploadObserver>*)observer {
	return observer;
}

-(void)notifyDelegateOfProgress:(NSArray *)args {
	[[self observer] uploadMadeProgress:[args objectAtIndex:0]
						   bytesWritten:[[args objectAtIndex:1] longValue]
						   ofTotalBytes:[[args objectAtIndex:2] longValue]];
}

-(void)uploadMadeProgress:(SMRequest *)request bytesWritten:(long)numberOfBytes ofTotalBytes:(long)totalBytes {
	[self performSelectorOnMainThread:@selector(notifyDelegateOfProgress:) 
						   withObject:[NSArray arrayWithObjects:[request imageData], [NSNumber numberWithLong:numberOfBytes], [NSNumber numberWithLong:totalBytes], nil]
						waitUntilDone:NO];
}

-(void)uploadCanceled:(SMRequest *)request {
	[[self observer] performSelectorOnMainThread:@selector(uploadWasCanceled)
									  withObject:nil
								   waitUntilDone:NO];	
}

-(void)uploadFailed:(SMRequest *)request withError:(NSString *)reason {
	SMResponse *resp = [SMResponse responseWithData:[request data] decoder:[self decoder]];
	[[self observer] performSelectorOnMainThread:@selector(uploadDidFail:)
									  withObject:resp
								   waitUntilDone:NO];
}

-(void)notifyDelegateOfUploadSuccess:(SMResponse *)resp {
	NSString *filename = [[[self lastUploadRequest] requestDict] objectForKey:SMUploadKeyFilename];
	NSData *data = [[self lastUploadRequest] imageData];
	[[self observer] uploadDidSucceed:resp filename:filename data:data];
}

-(void)uploadSucceeded:(SMRequest *)request {
	SMResponse *resp = [SMResponse responseWithData:[request data] decoder:[self decoder]];
	SMImageRef *ref = [SMImageRef refWithDictionary:[[resp response] objectForKey:@"Image"]];
	[resp setSMData:ref];
	[self performSelectorOnMainThread:@selector(notifyDelegateOfUploadSuccess:)
						   withObject:resp
						waitUntilDone:NO];
}

-(void)stopUpload {
	[[self lastUploadRequest] cancelUpload];
}

-(SMRequest *)lastUploadRequest {
	return lastUploadRequest;
}

-(void)setLastUploadRequest:(SMRequest *)request {
	if(lastUploadRequest != request) {
		[lastUploadRequest release];
		lastUploadRequest = [request retain];
	}
}

@end


