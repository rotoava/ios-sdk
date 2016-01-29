//
//  UpYun.m
//  UpYunSDK
//
//  Created by jack zhou on 13-8-6.
//  Copyright (c) 2013年 upyun. All rights reserved.
//

#import "UpYun.h"
#import "UPMultipartBody.h"
#import "NSString+NSHash.h"
#import "UPMutUploaderManager.h"

#define ERROR_DOMAIN @"UpYun.m"

#define REQUEST_URL(bucket) [NSURL URLWithString:[NSString stringWithFormat:@"%@%@/", FormAPIDomain, bucket]]

#define SUB_SAVE_KEY_FILENAME @"{filename}"


@implementation UpYun
- (instancetype)init {
    if (self = [super init]) {
        self.bucket = [DEFAULT_BUCKET copy];
        self.expiresIn = DEFAULT_EXPIRES_IN;
        self.passcode = [DEFAULT_PASSCODE copy];
        self.mutUploadSize = DEFAULT_MUTUPLOAD_SIZE;
        self.retryTimes = DEFAULT_RETRY_TIMES;
    }
    return self;
}

- (void)uploadImage:(UIImage *)image savekey:(NSString *)savekey {
    NSData *imageData = UIImagePNGRepresentation(image);
    [self uploadImageData:imageData savekey:savekey];
}

- (void)uploadImagePath:(NSString *)path savekey:(NSString *)savekey {
    [self uploadFilePath:path savekey:savekey];
}

- (void)uploadImageData:(NSData *)data savekey:(NSString *)savekey {
    [self uploadFileData:data savekey:savekey];
}

- (void)uploadFilePath:(NSString *)path savekey:(NSString *)savekey {
    if (![self checkFilePath:path]) {
        return;
    }
    [self uploadSavekey:savekey data:nil filePath:path];
}

- (void)uploadFileData:(NSData *)data savekey:(NSString *)savekey {
    if (![self checkSavekey:savekey]) {
        return;
    }
    [self uploadSavekey:savekey data:data filePath:nil];
}

- (void)uploadSavekey:(NSString *)savekey data:(NSData*)data filePath:(NSString*)filePath {
    
    NSInteger fileSize = data.length;
    if (filePath) {
        NSDictionary *fileDictionary = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
        fileSize = [fileDictionary fileSize];
    }
    
    if (fileSize > self.mutUploadSize) {
        [self mutUploadWithFileData:data FilePath:filePath SaveKey:savekey RetryTimes:_retryTimes];
    } else {
        [self formUploadWithFileData:data FilePath:filePath SaveKey:savekey RetryTimes:_retryTimes];
    }
}

- (void)uploadFile:(id)file saveKey:(NSString *)saveKey {

    if([file isKindOfClass:[UIImage class]]) {
        [self uploadImage:file savekey:saveKey];
    } else if([file isKindOfClass:[NSData class]]) {
        [self uploadFileData:file savekey:saveKey];
    } else if([file isKindOfClass:[NSString class]]) {
        [self uploadFilePath:file savekey:saveKey];
    }
}

#pragma mark----form upload

- (void)formUploadWithFileData:(NSData *)data
                      FilePath:(NSString *)filePath
                       SaveKey:(NSString *)savekey
                    RetryTimes:(NSInteger)retryTimes {
    
    __weak typeof(self)weakSelf = self;
    
    //进度回调
    HttpProgressBlock httpProgress = ^(int64_t completedBytesCount, int64_t totalBytesCount) {
        CGFloat percent = completedBytesCount/(float)totalBytesCount;
        if (_progressBlocker) {
            _progressBlocker(percent, totalBytesCount);
        }
    };
    //成功回调
    HttpSuccessBlock httpSuccess = ^(NSURLResponse *response, id responseData) {
        NSError *error;
        NSDictionary *jsonDic = [NSJSONSerialization JSONObjectWithData:responseData options:kNilOptions error:&error];
        NSString *message = [jsonDic objectForKey:@"message"];
        if ([@"ok" isEqualToString:message]) {
            if (_successBlocker) {
                _successBlocker(response, jsonDic);
            }
        } else {
            NSError *err = [NSError errorWithDomain:ERROR_DOMAIN
                                               code:[[jsonDic objectForKey:@"code"] intValue]
                                           userInfo:jsonDic];
            if (_failBlocker) {
                _failBlocker(err);
            }
        }
    };
    
    //失败回调
    HttpFailBlock httpFail = ^(NSError * error) {
        
        if (retryTimes > 0 && error.code/5 == 100) {
            [weakSelf formUploadWithFileData:data FilePath:filePath SaveKey:savekey RetryTimes:retryTimes-1];
        } else {
            if (_failBlocker) {
                _failBlocker(error);
            }
        }
    };
    
    NSString *policy = [self getPolicyWithSaveKey:savekey];
    __block NSString *signature = @"";
    if (_signatureBlocker) {
        dispatch_async(dispatch_get_main_queue(), ^(){
            signature = _signatureBlocker([policy stringByAppendingString:@"&"]);
        });
    } else if (self.passcode.length > 0) {
        signature = [self getSignatureWithPolicy:policy];
    } else {
        NSString *message = _signatureBlocker ? @"没有提供密钥" : @"没有实现signatureBlock";
        NSError *err = [NSError errorWithDomain:ERROR_DOMAIN
                                           code:-1999
                                       userInfo:@{@"message":message}];
        if (_failBlocker) {
            _failBlocker(err);
        }
        return;
    }
    
    UPMultipartBody *multiBody = [[UPMultipartBody alloc]init];
    [multiBody addDictionary:@{@"policy":policy, @"signature":signature}];
    [multiBody addFileData:data OrFilePath:filePath fileName:@"file" fileType:nil];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:REQUEST_URL(self.bucket)];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [multiBody dataFromPart];
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", multiBody.boundary] forHTTPHeaderField:@"Content-Type"];
    
    UPHTTPClient *client = [[UPHTTPClient alloc]init];
    [client uploadRequest:request success:httpSuccess failure:httpFail progress:httpProgress];
}

#pragma mark----mut upload

- (void)mutUploadWithFileData:(NSData *)data
                     FilePath:(NSString *)filePath
                      SaveKey:(NSString *)savekey
                   RetryTimes:(NSInteger)retryTimes {
    NSDictionary *fileInfo = [UPMutUploaderManager getFileInfoDicWithFileData:data OrFilePath:filePath];
    NSDictionary *signaturePolicyDic = [self constructingSignatureAndPolicyWithFileInfo:fileInfo saveKey:savekey];
    
    NSString *signature = signaturePolicyDic[@"signature"];
    NSString *policy = signaturePolicyDic[@"policy"];
    
    [UPMutUploaderManager setServer:[FormAPIDomain copy]];
    UPMutUploaderManager *manager = [[UPMutUploaderManager alloc]initWithBucket:self.bucket];

    __weak typeof(self)weakSelf = self;
    [manager uploadWithFile:data OrFilePath: filePath policy:policy signature:signature progressBlock:_progressBlocker completeBlock:^(NSError *error, NSDictionary *result, BOOL completed) {
            if (completed) {
                if (_successBlocker) {
                    _successBlocker(result[@"response"], result[@"responseData"]);
                }
            } else {
                if (retryTimes > 0 && error.code/5 == 100) {
                    [weakSelf mutUploadWithFileData:data FilePath:filePath SaveKey:savekey RetryTimes:retryTimes-1];
                } else {
                    if (_failBlocker) {
                        _failBlocker(error);
                    }
                }
            }
    }];
}

#pragma mark--Utils---

/**
 *  根据文件信息生成Signature\Policy (安全起见，以下算法应在服务端完成)
 *  @param paramaters 文件信息
 *  @return
 */
- (NSDictionary *)constructingSignatureAndPolicyWithFileInfo:(NSDictionary *)fileInfo saveKey:(NSString*) saveKey{
    NSMutableDictionary *mutableDic = [[NSMutableDictionary alloc]initWithDictionary:fileInfo];
    [mutableDic setObject:DATE_STRING(self.expiresIn) forKey:@"expiration"];//设置授权过期时间
    [mutableDic setObject:saveKey forKey:@"path"];//设置保存路径
    /**
     *  这个 mutableDic 可以塞入其他可选参数 见：http://docs.upyun.com/api/multipart_upload/#_2
     */
    
    NSString *policy = [self dictionaryToJSONStringBase64Encoding:mutableDic];
    
    __block NSString *signature = @"";
    if (_signatureBlocker) {
        dispatch_async(dispatch_get_main_queue(), ^(){
            signature = _signatureBlocker(policy);
        });
    } else if (self.passcode) {
        NSArray *keys = [[mutableDic allKeys] sortedArrayUsingSelector:@selector(compare:)];
        for (NSString * key in keys) {
            NSString * value = mutableDic[key];
            signature = [NSString stringWithFormat:@"%@%@%@", signature, key, value];
        }
        signature = [signature stringByAppendingString:self.passcode];
    } else {
        NSString *message = _signatureBlocker ? @"没有提供密钥" : @"没有实现signatureBlock";
        NSError *err = [NSError errorWithDomain:ERROR_DOMAIN
                                           code:-1999
                                       userInfo:@{@"message":message}];
        if (_failBlocker) {
            _failBlocker(err);
        }
    }
    return @{@"signature":[signature MD5],
             @"policy":policy};
}

- (NSString *)getPolicyWithSaveKey:(NSString *)savekey {
    NSMutableDictionary *dic = [NSMutableDictionary dictionary];
    [dic setObject:self.bucket forKey:@"bucket"];
    [dic setObject:DATE_STRING(self.expiresIn) forKey:@"expiration"];
    if (savekey && ![savekey isEqualToString:@""]) {
        [dic setObject:savekey forKey:@"save-key"];
    }
    
    if (self.params) {
        for (NSString *key in self.params.keyEnumerator) {
            [dic setObject:[self.params objectForKey:key] forKey:key];
        }
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:dic options:NSJSONWritingPrettyPrinted error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [json Base64encode];
}

- (NSString *)getSignatureWithPolicy:(NSString *)policy {
    NSString *str = [NSString stringWithFormat:@"%@&%@", policy, self.passcode];
    NSString *signature = [[[str dataUsingEncoding:NSUTF8StringEncoding] MD5HexDigest] lowercaseString];
    return signature;
}

- (NSString *)dictionaryToJSONStringBase64Encoding:(NSDictionary *)dic {
    id paramesData = [NSJSONSerialization dataWithJSONObject:dic options:0 error:nil];
    NSString *jsonString = [[NSString alloc] initWithData:paramesData
                                                 encoding:NSUTF8StringEncoding];
    return [jsonString Base64encode];
}

- (BOOL)checkSavekey:(NSString *)string {
    NSRange rangeFileName;
    NSRange rangeFileNameOnDic;
    rangeFileNameOnDic.location = NSNotFound;
    rangeFileName = [string rangeOfString:SUB_SAVE_KEY_FILENAME];
    if ([_params objectForKey:@"save-key"]) {
        rangeFileNameOnDic = [[_params objectForKey:@"save-key"]
                              rangeOfString:SUB_SAVE_KEY_FILENAME];
    }

    if(rangeFileName.location != NSNotFound || rangeFileNameOnDic.location != NSNotFound) {
        NSString *message = [NSString stringWithFormat:@"传入file为NSData或者UIImage时,不能使用%@方式生成savekey", SUB_SAVE_KEY_FILENAME];
        NSError *err = [NSError errorWithDomain:ERROR_DOMAIN
                                           code:-1998
                                       userInfo:@{@"message":message}];
        if (_failBlocker) {
            _failBlocker(err);
        }
        return NO;
    }
    return YES;
}

- (BOOL)checkFilePath:(NSString *)filePath {
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        NSString *message = [NSString stringWithFormat:@"传入filepath找不到文件, %@", filePath];
        NSError *err = [NSError errorWithDomain:ERROR_DOMAIN
                                           code:-1997
                                       userInfo:@{@"message":message}];
        if (_failBlocker) {
            _failBlocker(err);
        }

        return NO;
    }
    return YES;
}

@end