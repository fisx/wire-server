{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE ViewPatterns      #-}

-- TODO: Move to Brig.User.Account.DB
module Brig.Data.User
    ( AuthError (..)
    , ReAuthError (..)
    , newAccount
    , authenticate
    , reauthenticate
    , filterActive
    , isActivated
    , lookupAccount
    , lookupAccounts
    , lookupUser
    , lookupUsers
    , lookupName
    , lookupLocale
    , lookupPassword
    , lookupStatus
    , insertAccount
    , updateUser
    , updateEmail
    , updatePhone
    , activateUser
    , deactivateUser
    , updateLocale
    , updatePassword
    , updateStatus
    , updateSearchableStatus
    , deleteEmail
    , deletePhone
    , updateHandle
    ) where

import Brig.App (AppIO, settings)
import Brig.Data.Instances ()
import Brig.Options
import Brig.Password
import Brig.Types
import Brig.Types.Intra
import Cassandra
import Control.Error
import Control.Lens hiding (from)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Data.Foldable (for_)
import Data.Id
import Data.Misc (PlainTextPassword (..))
import Data.UUID.V4
import Galley.Types.Bot

-- | Authentication errors.
data AuthError
    = AuthInvalidUser
    | AuthInvalidCredentials
    | AuthSuspended

-- | Re-authentication errors.
data ReAuthError
    = ReAuthError !AuthError
    | ReAuthMissingPassword

newAccount :: NewUser -> Maybe InvitationId -> AppIO (UserAccount, Maybe Password)
newAccount u inv = do
    defLoc  <- setDefaultLocale <$> view settings
    uid     <- Id <$> maybe (liftIO nextRandom) (return . toUUID) inv
    passwd  <- maybe (return Nothing) (fmap Just . liftIO . mkSafePassword) pass
    return (UserAccount (user uid $ locale defLoc) Active, passwd)
  where
    ident         = newUserIdentity u
    pass          = newUserPassword u
    name          = newUserName u
    pict          = fromMaybe noPict (newUserPict u)
    assets        = newUserAssets u
    colour        = fromMaybe defaultAccentId (newUserAccentId u)
    locale defLoc = fromMaybe defLoc (newUserLocale u)
    user   uid l  = User uid ident name pict assets colour False l Nothing Nothing

-- | Mandatory password authentication.
authenticate :: UserId -> PlainTextPassword -> ExceptT AuthError AppIO ()
authenticate u pw = lift (lookupAuth u) >>= \case
    Nothing                   -> throwE AuthInvalidUser
    Just (_,         Deleted) -> throwE AuthInvalidUser
    Just (_,       Suspended) -> throwE AuthSuspended
    Just (Nothing,         _) -> throwE AuthInvalidCredentials
    Just (Just pw',   Active) ->
        unless (verifyPassword pw pw') $
            throwE AuthInvalidCredentials

-- | Password reauthentication. If the account has a password, reauthentication
-- is mandatory. If the account has no password and no password is given,
-- reauthentication is a no-op.
reauthenticate :: UserId -> Maybe PlainTextPassword -> ExceptT ReAuthError AppIO ()
reauthenticate u pw = lift (lookupAuth u) >>= \case
    Nothing                   -> throwE (ReAuthError AuthInvalidUser)
    Just (_,         Deleted) -> throwE (ReAuthError AuthInvalidUser)
    Just (_,       Suspended) -> throwE (ReAuthError AuthSuspended)
    Just (Nothing,         _) -> for_ pw $ const (throwE $ ReAuthError AuthInvalidCredentials)
    Just (Just pw',   Active) -> case pw of
        Nothing -> throwE ReAuthMissingPassword
        Just  p ->
            unless (verifyPassword p pw') $
                throwE (ReAuthError AuthInvalidCredentials)

insertAccount :: UserAccount -> Maybe Password -> Bool -> SearchableStatus -> AppIO ()
insertAccount (UserAccount u status) password activated searchable = do
    let Locale l c = userLocale u
    retry x5 $ write userInsert $ params Quorum
        ( userId u, userName u, userPict u, userAssets u, userEmail u
        , userPhone u, userAccentId u, password, activated
        , status, l, c
        , view serviceRefProvider <$> userService u
        , view serviceRefId <$> userService u
        , userHandle u
        , searchable
        )

updateLocale :: UserId -> Locale -> AppIO ()
updateLocale u (Locale l c) = write userLocaleUpdate (params Quorum (l, c, u))

updateUser :: UserId -> UserUpdate -> AppIO ()
updateUser u UserUpdate{..} = do
    for_ uupName     $ \n -> write userNameUpdate     (params Quorum (n, u))
    for_ uupPict     $ \p -> write userPictUpdate     (params Quorum (p, u))
    for_ uupAssets   $ \a -> write userAssetsUpdate   (params Quorum (a, u))
    for_ uupAccentId $ \c -> write userAccentIdUpdate (params Quorum (c, u))

updateEmail :: UserId -> Email -> AppIO ()
updateEmail u e = retry x5 $ write userEmailUpdate (params Quorum (e, u))

updatePhone :: UserId -> Phone -> AppIO ()
updatePhone u p = retry x5 $ write userPhoneUpdate (params Quorum (p, u))

updateHandle :: UserId -> Handle -> AppIO ()
updateHandle u h = retry x5 $ write userHandleUpdate (params Quorum (h, u))

updatePassword :: UserId -> PlainTextPassword -> AppIO ()
updatePassword u t = do
    p <- liftIO $ mkSafePassword t
    retry x5 $ write userPasswordUpdate (params Quorum (p, u))

deleteEmail :: UserId -> AppIO ()
deleteEmail u = retry x5 $ write userEmailDelete (params Quorum (Identity u))

deletePhone :: UserId -> AppIO ()
deletePhone u = retry x5 $ write userPhoneDelete (params Quorum (Identity u))

updateStatus :: UserId -> AccountStatus -> AppIO ()
updateStatus u s = retry x5 $ write userStatusUpdate (params Quorum (s, u))

updateSearchableStatus :: UserId -> SearchableStatus -> AppIO ()
updateSearchableStatus u s =
    retry x5 $ write userSearchableStatusUpdate (params Quorum (s, u))

-- | Whether the account has been activated by verifying
-- an email address or phone number.
isActivated :: UserId -> AppIO Bool
isActivated u = (== Just (Identity True)) <$>
    retry x1 (query1 activatedSelect (params Quorum (Identity u)))

filterActive :: [UserId] -> AppIO [UserId]
filterActive us = map (view _1) . filter isActiveUser <$>
    retry x1 (query accountStateSelectAll (params Quorum (Identity us)))
  where
    isActiveUser :: (UserId, Bool, Maybe AccountStatus) -> Bool
    isActiveUser (_, True, Just Active) = True
    isActiveUser  _                     = False

lookupUser :: UserId -> AppIO (Maybe User)
lookupUser u = listToMaybe <$> lookupUsers [u]

activateUser :: UserId -> UserIdentity -> AppIO ()
activateUser u ident = do
    let email = emailIdentity ident
    let phone = phoneIdentity ident
    retry x5 $ write userActivatedUpdate (params Quorum (email, phone, u))

deactivateUser :: UserId -> AppIO ()
deactivateUser u =
    retry x5 $ write userDeactivatedUpdate (params Quorum (Identity u))

lookupLocale :: UserId -> AppIO (Maybe Locale)
lookupLocale u = do
    defLoc <- setDefaultLocale <$> view settings
    fmap (toLocale defLoc) <$> retry x1 (query1 localeSelect (params Quorum (Identity u)))

lookupName :: UserId -> AppIO (Maybe Name)
lookupName u = fmap runIdentity <$>
    retry x1 (query1 nameSelect (params Quorum (Identity u)))

lookupPassword :: UserId -> AppIO (Maybe Password)
lookupPassword u = join . fmap runIdentity <$>
    retry x1 (query1 passwordSelect (params Quorum (Identity u)))

lookupStatus :: UserId -> AppIO (Maybe AccountStatus)
lookupStatus u = join . fmap runIdentity <$>
    retry x1 (query1 statusSelect (params Quorum (Identity u)))

lookupAuth :: UserId -> AppIO (Maybe (Maybe Password, AccountStatus))
lookupAuth u = fmap f <$> retry x1 (query1 authSelect (params Quorum (Identity u)))
  where
    f (pw, st) = (pw, fromMaybe Active st)

lookupUsers :: [UserId] -> AppIO [User]
lookupUsers usrs = do
    loc <- setDefaultLocale  <$> view settings
    toUsers loc <$> retry x1 (query usersSelect (params Quorum (Identity usrs)))

lookupAccount :: UserId -> AppIO (Maybe UserAccount)
lookupAccount u = listToMaybe <$> lookupAccounts [u]

lookupAccounts :: [UserId] -> AppIO [UserAccount]
lookupAccounts usrs = do
    loc <- setDefaultLocale  <$> view settings
    fmap (toUserAccount loc) <$> retry x1 (query accountsSelect (params Quorum (Identity usrs)))

-------------------------------------------------------------------------------
-- Queries

type Activated = Bool

type UserRow = (UserId, Name, Maybe Pict, Maybe Email, Maybe Phone, ColourId,
                Maybe [Asset], Activated, Maybe AccountStatus, Maybe Language,
                Maybe Country, Maybe ProviderId, Maybe ServiceId, Maybe Handle)

type AccountRow = (UserId, Name, Maybe Pict, Maybe Email, Maybe Phone,
                   ColourId, Maybe [Asset], Bool, Maybe AccountStatus,
                   Maybe Language, Maybe Country,
                   Maybe ProviderId, Maybe ServiceId, Maybe Handle)

usersSelect :: PrepQuery R (Identity [UserId]) UserRow
usersSelect = "SELECT id, name, picture, email, phone, accent_id, assets, \
              \activated, status, language, country, provider, service, handle \
              \FROM user where id IN ?"

nameSelect :: PrepQuery R (Identity UserId) (Identity Name)
nameSelect = "SELECT name FROM user WHERE id = ?"

localeSelect :: PrepQuery R (Identity UserId) (Maybe Language, Maybe Country)
localeSelect = "SELECT language, country FROM user WHERE id = ?"

authSelect :: PrepQuery R (Identity UserId) (Maybe Password, Maybe AccountStatus)
authSelect = "SELECT password, status FROM user WHERE id = ?"

passwordSelect :: PrepQuery R (Identity UserId) (Identity (Maybe Password))
passwordSelect = "SELECT password FROM user WHERE id = ?"

activatedSelect :: PrepQuery R (Identity UserId) (Identity Bool)
activatedSelect = "SELECT activated FROM user WHERE id = ?"

accountStateSelectAll :: PrepQuery R (Identity [UserId]) (UserId, Bool, Maybe AccountStatus)
accountStateSelectAll = "SELECT id, activated, status FROM user WHERE id IN ?"

statusSelect :: PrepQuery R (Identity UserId) (Identity (Maybe AccountStatus))
statusSelect = "SELECT status FROM user WHERE id = ?"

accountsSelect :: PrepQuery R (Identity [UserId]) AccountRow
accountsSelect = "SELECT id, name, picture, email, phone, accent_id, assets, \
                 \activated, status, language, country, provider, \
                 \service, handle \
                 \FROM user WHERE id IN ?"

userInsert :: PrepQuery W (UserId, Name, Pict, [Asset], Maybe Email, Maybe Phone,
                           ColourId, Maybe Password, Bool, AccountStatus, Language,
                           Maybe Country, Maybe ProviderId,
                           Maybe ServiceId, Maybe Handle, SearchableStatus) ()
userInsert = "INSERT INTO user (id, name, picture, assets, email, phone, \
                               \accent_id, password, activated, status, language, \
                               \country, provider, service, handle, searchable) \
                               \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"

userNameUpdate :: PrepQuery W (Name, UserId) ()
userNameUpdate = "UPDATE user SET name = ? WHERE id = ?"

userPictUpdate :: PrepQuery W (Pict, UserId) ()
userPictUpdate = "UPDATE user SET picture = ? WHERE id = ?"

userAssetsUpdate :: PrepQuery W ([Asset], UserId) ()
userAssetsUpdate = "UPDATE user SET assets = ? WHERE id = ?"

userAccentIdUpdate :: PrepQuery W (ColourId, UserId) ()
userAccentIdUpdate = "UPDATE user SET accent_id = ? WHERE id = ?"

userEmailUpdate :: PrepQuery W (Email, UserId) ()
userEmailUpdate = "UPDATE user SET email = ? WHERE id = ?"

userPhoneUpdate :: PrepQuery W (Phone, UserId) ()
userPhoneUpdate = "UPDATE user SET phone = ? WHERE id = ?"

userHandleUpdate :: PrepQuery W (Handle, UserId) ()
userHandleUpdate = "UPDATE user SET handle = ? WHERE id = ?"

userPasswordUpdate :: PrepQuery W (Password, UserId) ()
userPasswordUpdate = "UPDATE user SET password = ? WHERE id = ?"

userStatusUpdate :: PrepQuery W (AccountStatus, UserId) ()
userStatusUpdate = "UPDATE user SET status = ? WHERE id = ?"

userSearchableStatusUpdate :: PrepQuery W (SearchableStatus, UserId) ()
userSearchableStatusUpdate = "UPDATE user SET searchable = ? WHERE id = ?"

userDeactivatedUpdate :: PrepQuery W (Identity UserId) ()
userDeactivatedUpdate = "UPDATE user SET activated = false WHERE id = ?"

userActivatedUpdate :: PrepQuery W (Maybe Email, Maybe Phone, UserId) ()
userActivatedUpdate = "UPDATE user SET activated = true, email = ?, phone = ? WHERE id = ?"

userLocaleUpdate :: PrepQuery W (Language, Maybe Country, UserId) ()
userLocaleUpdate = "UPDATE user SET language = ?, country = ? WHERE id = ?"

userEmailDelete :: PrepQuery W (Identity UserId) ()
userEmailDelete = "UPDATE user SET email = null WHERE id = ?"

userPhoneDelete :: PrepQuery W (Identity UserId) ()
userPhoneDelete = "UPDATE user SET phone = null WHERE id = ?"

-------------------------------------------------------------------------------
-- Conversions

toUserAccount :: Locale -> AccountRow -> UserAccount
toUserAccount defaultLocale (uid, name, pict, email, phone, accent, assets,
                             activated, status, lan, con, pid, sid,
                             handle) =
    let ident = toIdentity activated email phone
        deleted = maybe False (== Deleted) status
        loc = toLocale defaultLocale (lan, con)
        svc = newServiceRef <$> sid <*> pid
    in UserAccount (User uid ident name (fromMaybe noPict pict)
                         (fromMaybe [] assets) accent deleted loc svc handle)
                   (fromMaybe Active status)

toUsers :: Locale -> [UserRow] -> [User]
toUsers defaultLocale = fmap mk
  where
    mk (uid, name, pict, email, phone, accent, assets, activated, status,
        lan, con, pid, sid, handle) =
        let ident = toIdentity activated email phone
            deleted = maybe False (== Deleted) status
            loc = toLocale defaultLocale (lan, con)
            svc = newServiceRef <$> sid <*> pid
        in User uid ident name (fromMaybe noPict pict) (fromMaybe [] assets)
                accent deleted loc svc handle

toLocale :: Locale -> (Maybe Language, Maybe Country) -> Locale
toLocale _ (Just l, c) = Locale l c
toLocale l _           = l

toIdentity :: Bool -> Maybe Email -> Maybe Phone -> Maybe UserIdentity
toIdentity True (Just e) (Just p) = Just $! FullIdentity e p
toIdentity True (Just e) Nothing  = Just $! EmailIdentity e
toIdentity True Nothing  (Just p) = Just $! PhoneIdentity p
toIdentity _    _        _        = Nothing
