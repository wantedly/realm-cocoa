////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMObject_Private.hpp"

#import "RLMAccessor.h"
#import "RLMArray_Private.hpp"
#import "RLMObjectSchema_Private.hpp"
#import "RLMObjectStore.h"
#import "RLMProperty_Private.h"
#import "RLMRealm_Private.hpp"
#import "RLMSchema_Private.h"
#import "RLMSwiftSupport.h"
#import "RLMUtil.hpp"

@interface RLMObjectBase () {
    @public
    std::unique_ptr<RLMObservationInfo2> _observationInfo;
}
@end

RLMObservationInfo2::RLMObservationInfo2(RLMObjectSchema *objectSchema, std::size_t row, id object)
: row((*objectSchema.table)[row])
, object(object)
, objectSchema(objectSchema)
{
    for (auto info : objectSchema->_observedObjects) {
        if (info->row.get_index() == row) {
            prev = info;
            next = info->next;
            info->next = this;
            return;
        }
    }
    objectSchema->_observedObjects.push_back(this);
}

RLMObservationInfo2::~RLMObservationInfo2() {
    if (prev) {
        prev->next = next;
        if (next)
            next->prev = prev;
    }
    else {
        for (auto it = objectSchema->_observedObjects.begin(), end = objectSchema->_observedObjects.end(); it != end; ++it) {
            if (*it == this) {
                if (next)
                    *it = next;
                else {
                    iter_swap(it, std::prev(end));
                    objectSchema->_observedObjects.pop_back();
                }
                return;
            }
        }
    }
}

const NSUInteger RLMDescriptionMaxDepth = 5;

@implementation RLMObjectBase
// standalone init
- (instancetype)init {
    if (RLMSchema.sharedSchema) {
        __unsafe_unretained RLMObjectSchema *const objectSchema = [self.class sharedSchema];
        self = [self initWithRealm:nil schema:objectSchema];

        // set default values
        if (!objectSchema.isSwiftClass) {
            NSDictionary *dict = RLMDefaultValuesForObjectSchema(objectSchema);
            for (NSString *key in dict) {
                [self setValue:dict[key] forKey:key];
            }
        }

        // set standalone accessor class
        object_setClass(self, objectSchema.standaloneClass);
    }
    else {
        // if schema not initialized
        // this is only used for introspection
        self = [super init];
    }

    return self;
}

- (void)dealloc {
#if 0
    if (!_nextObservable) {
        return;
    }

    for (auto it = _objectSchema->_observedObjects.begin(), end = _objectSchema->_observedObjects.end(); it != end; ++it) {
        if (*it == self) {
            if (_nextObservable == self) {
                iter_swap(it, prev(end));
                _objectSchema->_observedObjects.pop_back();
                return;
            }
            *it = _nextObservable;
            break;
        }
    }

    auto next = _nextObservable;
    while (next->_nextObservable != self)
        next = next->_nextObservable;
    next->_nextObservable = _nextObservable;
#endif
}

static id RLMValidatedObjectForProperty(id obj, RLMProperty *prop, RLMSchema *schema) {
    if (RLMIsObjectValidForProperty(obj, prop)) {
        return obj;
    }

    // check for object or array of properties
    if (prop.type == RLMPropertyTypeObject) {
        // for object create and try to initialize with obj
        RLMObjectSchema *objSchema = schema[prop.objectClassName];
        return [[objSchema.objectClass alloc] initWithValue:obj schema:schema];
    }
    else if (prop.type == RLMPropertyTypeArray && [obj conformsToProtocol:@protocol(NSFastEnumeration)]) {
        // for arrays, create objects for each element and return new array
        RLMObjectSchema *objSchema = schema[prop.objectClassName];
        RLMArray *objects = [[RLMArray alloc] initWithObjectClassName:objSchema.className parentObject:nil key:prop.name];
        for (id el in obj) {
            [objects addObject:[[objSchema.objectClass alloc] initWithValue:el schema:schema]];
        }
        return objects;
    }

    // if not convertible to prop throw
    @throw RLMException([NSString stringWithFormat:@"Invalid value '%@' for property '%@'", obj, prop.name]);
}

- (instancetype)initWithValue:(id)value schema:(RLMSchema *)schema {
    self = [self init];
    NSArray *properties = _objectSchema.properties;
    if (NSArray *array = RLMDynamicCast<NSArray>(value)) {
        if (array.count != properties.count) {
            @throw RLMException(@"Invalid array input. Number of array elements does not match number of properties.");
        }
        for (NSUInteger i = 0; i < array.count; i++) {
            [self setValue:RLMValidatedObjectForProperty(array[i], properties[i], schema) forKeyPath:[properties[i] name]];
        }
    }
    else {
        // assume our object is an NSDictionary or an object with kvc properties
        NSDictionary *defaultValues = nil;
        for (RLMProperty *prop in properties) {
            id obj = [value valueForKey:prop.name];

            // get default for nil object
            if (!obj) {
                if (!defaultValues) {
                    defaultValues = RLMDefaultValuesForObjectSchema(_objectSchema);
                }
                obj = defaultValues[prop.name];
            }

            [self setValue:RLMValidatedObjectForProperty(obj, prop, schema) forKeyPath:prop.name];
        }
    }

    return self;
}

- (instancetype)initWithRealm:(__unsafe_unretained RLMRealm *const)realm
                       schema:(__unsafe_unretained RLMObjectSchema *const)schema {
    self = [super init];
    if (self) {
        _realm = realm;
        _objectSchema = schema;
    }
    return self;
}

// overridden at runtime per-class for performance
+ (NSString *)className {
    NSString *className = NSStringFromClass(self);
    if ([RLMSwiftSupport isSwiftClassName:className]) {
        className = [RLMSwiftSupport demangleClassName:className];
    }
    return className;
}

// overridden at runtime per-class for performance
+ (RLMObjectSchema *)sharedSchema {
    return RLMSchema.sharedSchema[self.className];
}

- (NSString *)description
{
    if (self.isInvalidated) {
        return @"[invalid object]";
    }

    return [self descriptionWithMaxDepth:RLMDescriptionMaxDepth];
}

- (NSString *)descriptionWithMaxDepth:(NSUInteger)depth {
    if (depth == 0) {
        return @"<Maximum depth exceeded>";
    }

    NSString *baseClassName = _objectSchema.className;
    NSMutableString *mString = [NSMutableString stringWithFormat:@"%@ {\n", baseClassName];

    for (RLMProperty *property in _objectSchema.properties) {
        id object = RLMObjectBaseObjectForKeyedSubscript(self, property.name);
        NSString *sub;
        if ([object respondsToSelector:@selector(descriptionWithMaxDepth:)]) {
            sub = [object descriptionWithMaxDepth:depth - 1];
        }
        else if (property.type == RLMPropertyTypeData) {
            static NSUInteger maxPrintedDataLength = 24;
            NSData *data = object;
            NSUInteger length = data.length;
            if (length > maxPrintedDataLength) {
                data = [NSData dataWithBytes:data.bytes length:maxPrintedDataLength];
            }
            NSString *dataDescription = [data description];
            sub = [NSString stringWithFormat:@"<%@ — %lu total bytes>", [dataDescription substringWithRange:NSMakeRange(1, dataDescription.length - 2)], (unsigned long)length];
        }
        else {
            sub = [object description];
        }
        [mString appendFormat:@"\t%@ = %@;\n", property.name, [sub stringByReplacingOccurrencesOfString:@"\n" withString:@"\n\t"]];
    }
    [mString appendString:@"}"];

    return [NSString stringWithString:mString];
}

- (BOOL)isInvalidated {
    // if not standalone and our accessor has been detached, we have been deleted
    return self.class == _objectSchema.accessorClass && !_row.is_attached();
}

- (BOOL)isDeletedFromRealm {
    return self.isInvalidated;
}

- (BOOL)isEqual:(id)object {
    if (RLMObjectBase *other = RLMDynamicCast<RLMObjectBase>(object)) {
        if (_objectSchema.primaryKeyProperty) {
            return RLMObjectBaseAreEqual(self, other);
        }
    }
    return [super isEqual:object];
}

- (NSUInteger)hash {
    if (_objectSchema.primaryKeyProperty) {
        id primaryProperty = [self valueForKey:_objectSchema.primaryKeyProperty.name];

        // modify the hash of our primary key value to avoid potential (although unlikely) collisions
        return [primaryProperty hash] ^ 1;
    }
    else {
        return [super hash];
    }
}

+ (BOOL)shouldPersistToRealm {
    return RLMIsObjectSubclass(self);
}

- (id)mutableArrayValueForKey:(NSString *)key {
    id obj = [self valueForKey:key];
    if ([obj isKindOfClass:[RLMArray class]]) {
        return obj;
    }
    return [super mutableArrayValueForKey:key];
}

- (void)addObserver:(id)observer
         forKeyPath:(NSString *)keyPath
            options:(NSKeyValueObservingOptions)options
            context:(void *)context {
    if (!_observationInfo) {
        _observationInfo = std::make_unique<RLMObservationInfo2>(_objectSchema, _row.get_index(), self);
    }

    [super addObserver:observer forKeyPath:keyPath options:options context:context];
}

- (void *)observationInfo {
    return _observationInfo ? _observationInfo->kvoInfo : nullptr;
}

- (void)setObservationInfo:(void *)observationInfo {
    _observationInfo->kvoInfo = observationInfo;
}

@end

void RLMForEachObserver(RLMObjectBase *obj, void (^block)(RLMObjectBase*)) {
    RLMObservationInfo2 *info = obj->_observationInfo.get();
    if (!info) {
        for (RLMObservationInfo2 *o : obj->_objectSchema->_observedObjects) {
            if (obj->_row.get_index() == o->row.get_index()) {
                info = o;
                break;
            }
        }
    }
    for_each(info, block);
}

@implementation RLMObservationInfo
@end

void RLMObjectBaseSetRealm(__unsafe_unretained RLMObjectBase *object, __unsafe_unretained RLMRealm *realm) {
    if (object) {
        object->_realm = realm;
    }
}

RLMRealm *RLMObjectBaseRealm(__unsafe_unretained RLMObjectBase *object) {
    return object ? object->_realm : nil;
}

void RLMObjectBaseSetObjectSchema(__unsafe_unretained RLMObjectBase *object, __unsafe_unretained RLMObjectSchema *objectSchema) {
    if (object) {
        object->_objectSchema = objectSchema;
    }
}

RLMObjectSchema *RLMObjectBaseObjectSchema(__unsafe_unretained RLMObjectBase *object) {
    return object ? object->_objectSchema : nil;
}

NSArray *RLMObjectBaseLinkingObjectsOfClass(RLMObjectBase *object, NSString *className, NSString *property) {
    if (!object) {
        return nil;
    }

    if (!object->_realm) {
        @throw RLMException(@"Linking object only available for objects in a Realm.");
    }
    RLMCheckThread(object->_realm);

    if (!object->_row.is_attached()) {
        @throw RLMException(@"Object has been deleted or invalidated and is no longer valid.");
    }

    RLMObjectSchema *schema = object->_realm.schema[className];
    RLMProperty *prop = schema[property];
    if (!prop) {
        @throw RLMException([NSString stringWithFormat:@"Invalid property '%@'", property]);
    }

    if (![prop.objectClassName isEqualToString:object->_objectSchema.className]) {
        @throw RLMException([NSString stringWithFormat:@"Property '%@' of '%@' expected to be an RLMObject or RLMArray property pointing to type '%@'", property, className, object->_objectSchema.className]);
    }

    Table *table = schema.table;
    if (!table) {
        return @[];
    }

    size_t col = prop.column;
    NSUInteger count = object->_row.get_backlink_count(*table, col);
    NSMutableArray *links = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [links addObject:RLMCreateObjectAccessor(object->_realm, schema, object->_row.get_backlink(*table, col, i))];
    }
    return [links copy];
}

id RLMObjectBaseObjectForKeyedSubscript(RLMObjectBase *object, NSString *key) {
    if (!object) {
        return nil;
    }

    if (object->_realm) {
        return RLMDynamicGet(object, key);
    }
    else {
        return [object valueForKey:key];
    }
}

void RLMObjectBaseSetObjectForKeyedSubscript(RLMObjectBase *object, NSString *key, id obj) {
    if (!object) {
        return;
    }

    if (object->_realm) {
        RLMDynamicValidatedSet(object, key, obj);
    }
    else {
        [object setValue:obj forKey:key];
    }
}


BOOL RLMObjectBaseAreEqual(RLMObjectBase *o1, RLMObjectBase *o2) {
    // if not the correct types throw
    if ((o1 && ![o1 isKindOfClass:RLMObjectBase.class]) || (o2 && ![o2 isKindOfClass:RLMObjectBase.class])) {
        @throw RLMException(@"Can only compare objects of class RLMObjectBase");
    }
    // if identical object (or both are nil)
    if (o1 == o2) {
        return YES;
    }
    // if one is nil
    if (o1 == nil || o2 == nil) {
        return NO;
    }
    // if not in realm or differing realms
    if (o1->_realm == nil || o1->_realm != o2->_realm) {
        return NO;
    }
    // if either are detached
    if (!o1->_row.is_attached() || !o2->_row.is_attached()) {
        return NO;
    }
    // if table and index are the same
    return o1->_row.get_table() == o2->_row.get_table()
        && o1->_row.get_index() == o2->_row.get_index();
}


Class RLMObjectUtilClass(BOOL isSwift) {
    static Class objectUtilObjc = [RLMObjectUtil class];
    static Class objectUtilSwift = NSClassFromString(@"RealmSwift.ObjectUtil");
    return isSwift && objectUtilSwift ? objectUtilSwift : objectUtilObjc;
}

@implementation RLMObjectUtil

+ (NSString *)primaryKeyForClass:(Class)cls {
    return [cls primaryKey];
}

+ (NSArray *)ignoredPropertiesForClass:(Class)cls {
    return [cls ignoredProperties];
}

+ (NSArray *)indexedPropertiesForClass:(Class)cls {
    return [cls indexedProperties];
}

+ (NSArray *)getGenericListPropertyNames:(__unused id)obj {
    return nil;
}

+ (void)initializeListProperty:(__unused RLMObjectBase *)object property:(__unused RLMProperty *)property array:(__unused RLMArray *)array {
}

@end

void RLMOverrideStandaloneMethods(Class cls) {
    struct methodInfo {
        SEL sel;
        IMP imp;
        const char *type;
    };

    auto make = [](SEL sel, auto&& func) {
        Method m = class_getInstanceMethod(NSObject.class, sel);
        IMP superImp = method_getImplementation(m);
        const char *type = method_getTypeEncoding(m);
        IMP imp = imp_implementationWithBlock(func(sel, superImp));
        return methodInfo{sel, imp, type};
    };

    static const methodInfo methods[] = {
        make(@selector(addObserver:forKeyPath:options:context:), [](SEL sel, IMP superImp) {
            auto superFn = (void (*)(id, SEL, id, NSString *, NSKeyValueObservingOptions, void *))superImp;
            return ^(RLMObjectBase *self, id observer, NSString *keyPath, NSKeyValueObservingOptions options, void *context) {
                if (!self->_standaloneObservers)
                    self->_standaloneObservers = [NSMutableArray new];

                RLMObservationInfo *info = [RLMObservationInfo new];
                info.observer = observer;
                info.options = options;
                info.context = context;
                info.key = keyPath;
                [self->_standaloneObservers addObject:info];
                superFn(self, sel, observer, keyPath, options, context);
            };
        }),

        make(@selector(removeObserver:forKeyPath:), [](SEL sel, IMP superImp) {
            auto superFn = (void (*)(id, SEL, id, NSString *))superImp;
            return ^(RLMObjectBase *self, id observer, NSString *keyPath) {
                for (RLMObservationInfo *info in self->_standaloneObservers) {
                    if (info.observer == observer && [info.key isEqualToString:keyPath]) {
                        [self->_standaloneObservers removeObject:info];
                        break;
                    }
                }
                superFn(self, sel, observer, keyPath);
            };
        }),

        make(@selector(removeObserver:forKeyPath:context:), [](SEL sel, IMP superImp) {
            auto superFn = (void (*)(id, SEL, id, NSString *, void *))superImp;
            return ^(RLMObjectBase *self, id observer, NSString *keyPath, void *context) {
                for (RLMObservationInfo *info in self->_standaloneObservers) {
                    if (info.observer == observer && info.context == context && [info.key isEqualToString:keyPath]) {
                        [self->_standaloneObservers removeObject:info];
                        break;
                    }
                }
                superFn(self, sel, observer, keyPath, context);
            };
        })
    };

    for (auto const& m : methods)
        class_addMethod(cls, m.sel, m.imp, m.type);
}

void RLMTrackDeletions(__unsafe_unretained RLMRealm *const realm, dispatch_block_t block) {
    block();
    return;
#if 0
    struct change {
        __unsafe_unretained RLMObservable *observable;
        __unsafe_unretained NSString *property;
    };
    std::vector<change> changes;
    struct arrayChange {
        __unsafe_unretained RLMObservable *observable;
        __unsafe_unretained NSString *property;
        NSMutableIndexSet *indexes;
    };
    std::vector<arrayChange> arrayChanges;

    realm.group->notify_thing = [&](realm::ColumnBase::CascadeState const& cs) {
        for (auto const& row : cs.rows) {
            for (RLMObjectSchema *objectSchema in realm.schema.objectSchema) {
                if (objectSchema.table->get_index_in_group() != row.table_ndx)
                    continue;
                for (auto observer : objectSchema->_observers) {
                    if (observer->_row && observer->_row.get_index() == row.row_ndx) {
                        changes.push_back({observer, @"invalidated"});
                        for (RLMProperty *prop in objectSchema.properties)
                            changes.push_back({observer, prop.name});
                        break;
                    }
                }
                break;
            }
        }
        for (auto const& link : cs.links) {
            for (RLMObjectSchema *objectSchema in realm.schema.objectSchema) {
                if (objectSchema.table->get_index_in_group() != link.origin_table->get_index_in_group())
                    continue;
                for (auto observer : objectSchema->_observers) {
                    if (observer->_row.get_index() != link.origin_row_ndx)
                        continue;
                    RLMProperty *prop = objectSchema.properties[link.origin_col_ndx];
                    NSString *name = prop.name;
                    if (prop.type != RLMPropertyTypeArray)
                        changes.push_back({observer, name});
                    else {
                        auto linkview = observer->_row.get_linklist(prop.column);
                        arrayChange *c = nullptr;
                        for (auto& ac : arrayChanges) {
                            if (ac.observable == observer && ac.property == name) {
                                c = &ac;
                                break;
                            }
                        }
                        if (!c) {
                            arrayChanges.push_back({observer, name, [NSMutableIndexSet new]});
                            c = &arrayChanges.back();
                        }

                        size_t start = 0, index;
                        while ((index = linkview->find(link.old_target_row_ndx, start)) != realm::not_found) {
                            [c->indexes addIndex:index];
                            start = index + 1;
                        }
                    }
                    break;
               }
                break;
            }
        }

        for (auto const& change : changes)
            [change.observable willChangeValueForKey:change.property];
        for (auto const& change : arrayChanges)
            [change.observable willChange:NSKeyValueChangeRemoval valuesAtIndexes:change.indexes forKey:change.property];
    };

    block();

    for (auto const& change : changes) {
        change.observable->_returnNil = true;
        [change.observable didChangeValueForKey:change.property];
    }
    for (auto const& change : arrayChanges) {
        change.observable->_returnNil = true;
        [change.observable didChange:NSKeyValueChangeRemoval valuesAtIndexes:change.indexes forKey:change.property];
    }

    realm.group->notify_thing = nullptr;
#endif
}
